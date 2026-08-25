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
  quests_<locale>[id]   T title, O objectives text, D description
  units[id]         coords = { { x, y, zoneId, respawn }, ... }, lvl
  objects[id]       coords = { { x, y, zoneId, respawn }, ... }, fac
  items[id]         U = { unitId = dropRate }, O = { objectId = dropRate }
  zones[zoneId]     parentZoneOrContinent, width, height, xOffset, yOffset
  zones_<locale>[id]    localized area name
  minimap[zoneId]   zone width and height in yards
  meta[key]         service entity IDs -> faction token (A, H or AH)
  trainers[unitId]  { trainerType, trainerClass, trainerRace, trainerSpell,
                      trainerId }; trainerType 0 is a class trainer
  waypoint_index[unitId][continentGroup] = { routeId, ... }
  waypoint_routes[routeId].zones[zoneId] = {
                      { x, y, delay, script, orientation, order }, ... }

  Every "_enUS" text table above also ships as "_ruRU", "_zhCN", "_esES", and
  so on for every locale Database/ has a folder for. Client.GetLocale() picks
  which suffix this file reads at OnInit; LocaleTable() falls back to enUS
  for a locale the data has no table for, so the accessors below never touch
  the "_enUS" suffix directly.

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

-- Static service locations are cached per area/class/faction after their
-- first request. The source tables never change during a session, and doing
-- the relation walk once keeps map refreshes allocation-light.
Database.serviceLocationCache = {}
Database.serviceLocationCacheCount = 0

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

-- Static quest-location cache --------------------------------------------
-- GetQuestLocations walks the bundled relation tables, and the bundled data
-- never changes at runtime: for one (quest, completion, area, limit) tuple the
-- answer is fixed for the whole session. Both map layers ask for it again on
-- every rebuild and the HUD waypoint asks on every resolve, so the same walk
-- was being repeated for an answer that could not have differed. The cache is
-- keyed on the full argument tuple. OnInit invalidates it when `db` is
-- attached, and the safety bound below may evict it wholesale.
--
-- The returned list is shared, not copied. Callers must treat it as read-only.
-- QuestTarget:CollectLocations, the one caller that appends to a location
-- list, copies first; nothing else writes to a list it did not build itself.
local questLocationCache = {}
local questLocationCacheCount = 0

-- Same reasoning, one key: a quest's item-use targets are read straight out of
-- the bundled tables and never change. Keyed by quest, so it is bounded by the
-- 4433 bundled quests without a counter of its own.
local questItemUseTargetCache = {}

-- The map only ever asks about quests in the log, in the player's own area, so
-- the live key set is a few dozen entries. This bound is a safety net for a
-- session that somehow accumulates many zones and many quests, not an expected
-- path: flushing whole costs one repeat of a walk that was being run on every
-- refresh before this cache existed.
local MAX_QUEST_LOCATION_CACHE = 512

local function FlushQuestLocationCache()
    questLocationCache = {}
    questLocationCacheCount = 0
    questItemUseTargetCache = {}
end

local function CacheQuestLocations(cacheKey, locations)
    if questLocationCacheCount >= MAX_QUEST_LOCATION_CACHE then
        FlushQuestLocationCache()
    end
    questLocationCache[cacheKey] = locations
    questLocationCacheCount = questLocationCacheCount + 1
    return locations
end

-- Locale-suffixed text tables --------------------------------------------
-- The bundled data ships one text table per locale ("quests_enUS",
-- "quests_ruRU", ...); GetLocale() picks which suffix this client should
-- read. A locale the bundled data has no table for (or a client the wrapper
-- could not read a token from) falls back to enUS rather than going blank.
local locale = "enUS"

-- Returns db[baseName .. "_" .. locale] if that table exists, else
-- db[baseName .. "_enUS"]. Both are checked with type(), not existence alone,
-- since a malformed or half-loaded locale file must degrade the same way a
-- missing one does.
local function LocaleTable(baseName)
    if not db then
        return nil
    end
    local localized = db[baseName .. "_" .. locale]
    if type(localized) == "table" then
        return localized
    end
    return db[baseName .. "_enUS"]
end

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
    -- A new data table voids every walk cached against the old one.
    FlushQuestLocationCache()

    local resolved = UQ.Client and UQ.Client.GetLocale and UQ.Client.GetLocale()
    if type(resolved) == "string" and resolved ~= "" then
        locale = resolved
    end

    if db["quests_" .. locale] then
        UQ:DeclareCapability("questDatabaseLocale", "detected",
            "bundled world data has a quests_" .. locale .. " table; reading localized text through it")
    else
        UQ:DeclareCapability("questDatabaseLocale", "missing",
            "bundled world data has no quests_" .. locale .. " table; falling back to quests_enUS text")
    end

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
    local texts = LocaleTable("quests")
    if type(texts) ~= "table" then
        return nil
    end
    return texts[questId]
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
    local names = LocaleTable("units")
    if type(names) ~= "table" then
        return nil
    end
    return names[unitId]
end

-- Permanent open-world patrol routes for one creature in one direct area.
-- The lightweight unit index points into the two regional route files. Route
-- points already use the same database-area percentages as unit coordinates,
-- so the map layer can pass them through MapContext unchanged.
--
-- `closed` is true only when this area carries the route's complete original
-- waypoint order. Some routes are projected in full onto two adjacent area
-- maps; others genuinely cross a boundary and each map receives only a subset.
-- Counting zone tables cannot distinguish those cases, but point[6] can.
function Database:GetUnitPatrolRoutes(unitId, areaId)
    local routes = {}
    if not db or type(unitId) ~= "number" or type(areaId) ~= "number"
        or type(db.waypoint_index) ~= "table" or type(db.waypoint_routes) ~= "table" then
        return routes
    end

    local groups = db.waypoint_index[unitId]
    if type(groups) ~= "table" then
        return routes
    end

    local seen = {}
    local _, routeIds
    for _, routeIds in pairs(groups) do
        if type(routeIds) == "table" then
            local routeIndex = 1
            local routeTotal = table.getn(routeIds)
            while routeIndex <= routeTotal do
                local routeId = routeIds[routeIndex]
                local route = db.waypoint_routes[routeId]
                local points = type(route) == "table" and type(route.zones) == "table"
                    and route.zones[areaId] or nil
                if type(routeId) == "number" and not seen[routeId]
                    and type(points) == "table" and table.getn(points) > 0 then
                    seen[routeId] = true
                    local maxOrder = nil
                    local _, zonePoints
                    for _, zonePoints in pairs(route.zones) do
                        if type(zonePoints) == "table" then
                            local zonePointIndex = 1
                            local zonePointTotal = table.getn(zonePoints)
                            while zonePointIndex <= zonePointTotal do
                                local zonePoint = zonePoints[zonePointIndex]
                                local order = type(zonePoint) == "table" and zonePoint[6] or nil
                                if type(order) == "number" and (not maxOrder or order > maxOrder) then
                                    maxOrder = order
                                end
                                zonePointIndex = zonePointIndex + 1
                            end
                        end
                    end
                    local completeOrder = false
                    local pointTotal = table.getn(points)
                    local firstPoint = points[1]
                    local lastPoint = points[pointTotal]
                    if maxOrder and type(firstPoint) == "table" and type(lastPoint) == "table"
                        and firstPoint[6] == 1 and lastPoint[6] == maxOrder then
                        completeOrder = true
                        local pointIndex = 2
                        while pointIndex <= pointTotal do
                            local point = points[pointIndex]
                            local previous = points[pointIndex - 1]
                            if type(point) ~= "table" or type(previous) ~= "table"
                                or type(point[6]) ~= "number" or type(previous[6]) ~= "number"
                                or point[6] ~= previous[6] + 1 then
                                completeOrder = false
                                break
                            end
                            pointIndex = pointIndex + 1
                        end
                    end
                    table.insert(routes, {
                        routeId = routeId,
                        points = points,
                        closed = completeOrder,
                    })
                end
                routeIndex = routeIndex + 1
            end
        end
    end

    table.sort(routes, function(left, right)
        return left.routeId < right.routeId
    end)
    return routes
end

function Database:GetObject(objectId)
    if not db or type(db.objects) ~= "table" then
        return nil
    end
    return db.objects[objectId]
end

function Database:GetObjectName(objectId)
    local names = LocaleTable("objects")
    if type(names) ~= "table" then
        return nil
    end
    return names[objectId]
end

function Database:GetItem(itemId)
    if not db or type(db.items) ~= "table" then
        return nil
    end
    return db.items[itemId]
end

function Database:GetItemName(itemId)
    local names = LocaleTable("items")
    if type(names) ~= "table" then
        return nil
    end
    return names[itemId]
end

-- The whole area-name table, for callers that need to build a reverse index.
-- Exposed here so nothing outside this file has to reach for the data global.
function Database:GetZoneNames()
    return LocaleTable("zones")
end

function Database:GetZoneName(zoneId)
    local names = LocaleTable("zones")
    if type(names) ~= "table" then
        return nil
    end
    return names[zoneId]
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

-- Nearby service NPCs and objects ------------------------------------------

local SERVICE_META_KEYS = {
    "auctioneer",
    "banker",
    "battlemaster",
    "flight",
    "innkeeper",
    "mailbox",
    "meetingstone",
    "repair",
    "spirithealer",
    "stablemaster",
    "vendor",
}

-- The same meta table carries five world-node relations. They are kept apart
-- from the service keys because they are an order of magnitude larger -- one
-- zone holds up to ~800 herb spawns against a handful of innkeepers -- so they
-- are only walked for a category the caller actually asked for, and the result
-- is cached under a key that records which ones were included.
--
-- Their meta value is not a faction token: herbs and mines carry the required
-- gathering skill, rares the creature level, chests 0 and fishing pools "AH".
-- FactionAllows passes every non-string through, so a numeric value never
-- filters a node out; it is carried to the caller as `detail` instead.
local NODE_META_KEYS = {
    "chests",
    "fish",
    "herbs",
    "mines",
    "rares",
}

-- A service-only zone entry is a few dozen locations; a zone with herbs and
-- mines checked is closer to fifteen hundred. Roaming the world with nodes on
-- would otherwise grow this cache without bound, so it is flushed wholesale
-- once it holds more entries than a session plausibly revisits. Rebuilding one
-- costs the same walk the cache was added to avoid, not a correctness risk.
local MAX_SERVICE_LOCATION_CACHE = 48

local function PlayerFactionForRace(raceId)
    if raceId == 1 or raceId == 3 or raceId == 4 or raceId == 7 then
        return "A"
    end
    if raceId == 2 or raceId == 5 or raceId == 6 or raceId == 8 then
        return "H"
    end
    return nil
end

local function FactionAllows(token, playerFaction)
    if type(token) ~= "string" or token == "" or token == "AH" then
        return true
    end
    if not playerFaction then
        -- Missing player identity must over-show rather than silently remove
        -- every faction-tagged service from the map.
        return true
    end
    return token == playerFaction
end

-- Returns every service point in one direct area. `meta.lua` supplies the 11
-- service relations; unit/object records supply localized names and coords.
-- Class trainers are a twelfth category sourced from `trainers.lua`, limited
-- to trainer_type 0 and the player's measured numeric class ID. Profession,
-- mount and pet trainers deliberately do not leak into that option.
--
-- `wanted` is an optional category -> boolean set. It only gates NODE_META_KEYS;
-- the service relations are cheap enough to always gather, and callers that
-- pass nothing get exactly the previous service-only result.
function Database:GetAreaServiceLocations(areaId, playerClassId, playerRaceId, wanted)
    if not db or type(areaId) ~= "number" then
        return {}
    end

    local playerFaction = PlayerFactionForRace(playerRaceId)
    local nodeSignature = ""
    local nodeIndex = 1
    local nodeTotal = table.getn(NODE_META_KEYS)
    while nodeIndex <= nodeTotal do
        local include = type(wanted) == "table" and wanted[NODE_META_KEYS[nodeIndex]]
        nodeSignature = nodeSignature .. (include and "1" or "0")
        nodeIndex = nodeIndex + 1
    end
    local cacheKey = tostring(areaId) .. ":" .. tostring(playerClassId or 0)
        .. ":" .. tostring(playerFaction or "?") .. ":" .. nodeSignature
    local cached = self.serviceLocationCache[cacheKey]
    if cached then
        return cached
    end

    local locations = {}

    local function Append(category, rawId, faction, detail)
        if type(rawId) ~= "number" or not FactionAllows(faction, playerFaction) then
            return
        end
        local sourceType = "unit"
        local sourceId = rawId
        if rawId < 0 then
            sourceType = "object"
            sourceId = -rawId
        end
        local entity, name
        if sourceType == "unit" then
            entity = self:GetUnit(sourceId)
            name = self:GetUnitName(sourceId)
        else
            entity = self:GetObject(sourceId)
            name = self:GetObjectName(sourceId)
        end
        if type(entity) ~= "table" or type(entity.coords) ~= "table" then
            return
        end
        local coordIndex = 1
        local coordTotal = table.getn(entity.coords)
        while coordIndex <= coordTotal do
            local coordinate = entity.coords[coordIndex]
            if type(coordinate) == "table" and coordinate[3] == areaId
                and type(coordinate[1]) == "number" and type(coordinate[2]) == "number" then
                table.insert(locations, {
                    category = category,
                    x = coordinate[1],
                    y = coordinate[2],
                    areaId = areaId,
                    sourceType = sourceType,
                    sourceId = sourceId,
                    name = type(name) == "string" and name or category,
                    detail = detail,
                })
            end
            coordIndex = coordIndex + 1
        end
    end

    local meta = db.meta
    if type(meta) == "table" then
        local categoryIndex = 1
        local categoryTotal = table.getn(SERVICE_META_KEYS)
        while categoryIndex <= categoryTotal do
            local category = SERVICE_META_KEYS[categoryIndex]
            local relation = meta[category]
            if type(relation) == "table" then
                local rawId, faction
                for rawId, faction in pairs(relation) do
                    Append(category, rawId, faction)
                end
            end
            categoryIndex = categoryIndex + 1
        end

        nodeIndex = 1
        while nodeIndex <= nodeTotal do
            local category = NODE_META_KEYS[nodeIndex]
            local relation = meta[category]
            if type(wanted) == "table" and wanted[category] and type(relation) == "table" then
                local rawId, value
                for rawId, value in pairs(relation) do
                    -- The meta value doubles as the detail: a positive number
                    -- is a skill or a level, a string is a faction token.
                    if type(value) == "number" and value > 0 then
                        Append(category, rawId, nil, value)
                    else
                        Append(category, rawId, value, nil)
                    end
                end
            end
            nodeIndex = nodeIndex + 1
        end
    end

    if type(playerClassId) == "number" and type(db.trainers) == "table" then
        local unitId, trainer
        for unitId, trainer in pairs(db.trainers) do
            if type(trainer) == "table" and trainer[1] == 0
                and trainer[2] == playerClassId then
                local unit = self:GetUnit(unitId)
                Append("trainer", unitId, unit and unit.fac)
            end
        end
    end

    table.sort(locations, function(left, right)
        if left.category ~= right.category then
            return left.category < right.category
        end
        if left.name ~= right.name then
            return left.name < right.name
        end
        if left.x ~= right.x then
            return left.x < right.x
        end
        return left.y < right.y
    end)

    if self.serviceLocationCacheCount >= MAX_SERVICE_LOCATION_CACHE then
        self.serviceLocationCache = {}
        self.serviceLocationCacheCount = 0
    end
    self.serviceLocationCache[cacheKey] = locations
    self.serviceLocationCacheCount = self.serviceLocationCacheCount + 1
    return locations
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
    -- Static for the same reason GetQuestLocations is, and asked for on the
    -- same hot paths: GetQuestLocations seeds its visited set from this list,
    -- and QuestTarget consults it once to decide whether it has to copy.
    local cached = questItemUseTargetCache[questId]
    if cached then
        return cached
    end
    local relation = self:GetQuestObjectiveSources(questId)
    if type(relation) ~= "table" or type(relation.IR) ~= "table" then
        questItemUseTargetCache[questId] = targets
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

    questItemUseTargetCache[questId] = targets
    return targets
end

-- Builds the complete list of direct database coordinates for one active
-- quest in one area. Passing a numeric limit remains available to callers
-- that intentionally render a bounded non-objective surface such as turn-ins.
-- Item objectives are expanded through their unit/object source
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
    if type(limit) ~= "number" then
        limit = nil
    end
    -- See questLocationCache above: every input to the walk below is in this
    -- key, and none of the tables it reads can change while the session runs.
    local cacheKey = questId .. ":" .. (isComplete and "1" or "0")
        .. ":" .. areaId .. ":" .. (limit and tostring(limit) or "all")
    local cached = questLocationCache[cacheKey]
    if cached then
        return cached
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
        -- Absence is a static answer too. In particular, 174 bundled quests
        -- have no finisher relation, so repeated turn-in rebuilds must not
        -- repeat the same failed lookup.
        return CacheQuestLocations(cacheKey, {})
    end

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
        if (limit and table.getn(locations) >= limit)
            or type(sourceId) ~= "number" or type(record) ~= "table" then
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
        while index <= total and (not limit or table.getn(locations) < limit) do
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
            if limit and table.getn(locations) >= limit then
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

    return CacheQuestLocations(cacheKey, locations)
end

-- Every distinct area a quest's objective or finisher relation has a recorded
-- coordinate in, WITHOUT GetQuestLocations' current-zone filter. This cannot
-- place a pin -- the map layer only ever draws in the player's own uniquely
-- resolved current area -- but it answers a narrower, honestly-answerable
-- question a pin cannot: which zone(s) does the static data say this quest's
-- objectives or turn-in are actually in, so a caller can at least NAME the
-- zone to travel to when nothing is renderable in the current view. Same
-- relation-walking shape as GetQuestLocations (unit/object direct sources,
-- plus item-use sources), traversed the same way so the two can never
-- disagree about what "this quest's locations" means.
function Database:GetQuestAreaIds(questId, isComplete)
    if not db or type(questId) ~= "number" then
        return {}
    end
    local relation
    if isComplete then
        relation = self:GetQuestFinishers(questId)
    else
        relation = self:GetQuestObjectiveSources(questId)
    end
    if type(relation) ~= "table" then
        return {}
    end

    local seen = {}
    local areaIds = {}

    local function AppendAreasFrom(record)
        if type(record) ~= "table" or type(record.coords) ~= "table" then
            return
        end
        local index = 1
        local total = table.getn(record.coords)
        while index <= total do
            local coordinate = record.coords[index]
            if type(coordinate) == "table" and type(coordinate[3]) == "number"
                and not seen[coordinate[3]] then
                seen[coordinate[3]] = true
                table.insert(areaIds, coordinate[3])
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
                AppendAreasFrom(self:GetUnit(sourceId))
            else
                AppendAreasFrom(self:GetObject(sourceId))
            end
        end
    end

    AppendRelationSources("unit", relation.U)
    AppendRelationSources("object", relation.O)

    if type(relation.I) == "table" then
        local itemId
        for _, itemId in pairs(relation.I) do
            local item = self:GetItem(itemId)
            if type(item) == "table" then
                if type(item.U) == "table" then
                    local unitId
                    for unitId in pairs(item.U) do
                        AppendAreasFrom(self:GetUnit(unitId))
                    end
                end
                if type(item.O) == "table" then
                    local objectId
                    for objectId in pairs(item.O) do
                        AppendAreasFrom(self:GetObject(objectId))
                    end
                end
            end
        end
    end

    return areaIds
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

    if type(limit) ~= "number" then
        limit = nil
    end
    local coords = record.coords
    local index = 1
    local total = table.getn(coords)
    while index <= total and (not limit or table.getn(locations) < limit) do
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

    local texts = LocaleTable("quests")
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
-- is { x, y, areaId, sourceType, sourceId, faction, questIds }; faction is the
-- entity's A/H/AH token when the bundled data supplies one, and questIds is the
-- giver's own list and must be treated as read-only by callers.
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
                            faction = entity.fac,
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
