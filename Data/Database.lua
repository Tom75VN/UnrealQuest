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
  items[id]         U = { unitId = dropRate }, O = { objectId = dropRate },
                    V = { unitId = stockLimit }; V is the vendor relation and
                    its value is the vendor's limited stock (0 = unlimited),
                    never a faction token or a price
  zones[zoneId]     parentZoneOrContinent, width, height, xOffset, yOffset
  zones_<locale>[id]    localized area name
  minimap[zoneId]   zone width and height in yards
  meta[key]         service entity IDs -> faction token (A, H or AH)
  trainers[unitId]  { trainerType, trainerClass, trainerRace, trainerSpell,
                      trainerId }; trainerType 0 is a class trainer
  instances[mapId]  name, type (0 dungeon / 1 raid), min and entrances whose
                      trigger IDs resolve through areatrigger[id].coords
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

-- areaRankIndex[areaId] = { { unitId, rnk, coords = { coord, coord, ... } }, ... }
--
-- `units[id].rnk` is the creature's rank in the source world data: "1" elite,
-- "2" rare elite, "3" boss, "4" rare. 2635 of the 10385 bundled creatures
-- carry one; the rest are ordinary mobs with the field absent. Only 1182 of
-- those 2635 also carry world coordinates -- the others are instance-internal
-- creatures the reduction left without any -- so the index holds 1182
-- creatures over 1391 (creature, area) buckets. What makes it worth building
-- up front is that the alternative is walking all 10385 records and their
-- coordinate lists on every zone change.
--
-- `coords` holds REFERENCES to the coordinate tables already in the bundled
-- data, filtered to one area. Nothing here copies a coordinate and nothing may
-- write through one: this is a navigation index over data that never changes
-- during a session, and World/RareAlert.lua reads it every second.
--
-- The index is not built at load. It is started on demand by the first caller
-- that wants it (Database:StartRankIndex), because the only consumer is a
-- feature the player can turn off.
Database.areaRankIndex = nil
Database.rankIndexReady = false
Database.rankIndexRequested = false
Database.rankedUnitCount = 0

-- areaId -> { entrance, ... }: every recorded dungeon and raid entrance in
-- that area, resolved from Database/instances.lua through the areatriggers it
-- names. Each entrance keeps x/y at [1]/[2] for the proximity reader and also
-- carries normalized metadata for the finder map layer. Built on demand by
-- Database:GetInstanceEntrances below.
Database.instanceEntranceIndex = nil

local db = nil
local indexCursor = nil
local giverIndexCursor = nil
local rankIndexCursor = nil

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

-- The other half of the same walk: which obj.I items are only there because
-- obj.IR needs them used somewhere. Filled by GetQuestItemUseTargets so the
-- two can never disagree about which items are means rather than objectives.
local questItemUseRequirementCache = {}

-- And once more for the vendor targets of a quest's item objectives, which are
-- the same kind of static relation walk asked for on the same map refresh.
local questVendorTargetCache = {}

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
    questItemUseRequirementCache = {}
    questVendorTargetCache = {}
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

-- Unlike LocaleTable, this is an exact lookup with no English fallback. A
-- presentation asking for French must either receive the bundled French row
-- or nil, so a missing translation can fall back to the client's live title
-- instead of silently changing it to a third language.
local function ExactLocaleTable(baseName, language)
    if not db or type(language) ~= "string" or language == "" then
        return nil
    end
    local localized = db[baseName .. "_" .. language]
    if type(localized) ~= "table" then
        return nil
    end
    return localized
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
    self.instanceEntranceIndex = nil

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

-- Exact-language access for presentation only. Quest matching continues to
-- use GetQuestTitle/GetQuestText above, which are fixed to the CLIENT locale:
-- changing the addon's interface language must never change the title index
-- that resolves a live row to a database ID.
function Database:GetQuestTextForLanguage(questId, language)
    if type(questId) ~= "number" then
        return nil
    end
    local texts = ExactLocaleTable("quests", language)
    if not texts then
        return nil
    end
    return texts[questId]
end

function Database:GetQuestTitleForLanguage(questId, language)
    local text = self:GetQuestTextForLanguage(questId, language)
    if not text or type(text.T) ~= "string" or text.T == "" then
        return nil
    end
    return text.T
end

-- Expands the same quest-text variables the native Quest Log expands before
-- drawing a database description. pfQuest's FormatQuestText is the proven
-- prior art for this Vanilla token set ($N/$C/$R/$B/$G). If this client cannot
-- supply a value, or the bundled row contains an unknown token, nil makes the
-- caller retain the complete native field instead of exposing raw markup.
local function LowerASCII(value)
    local parts = {}
    local index = 1
    local length = string.len(value)
    while index <= length do
        local byte = string.byte(value, index)
        if byte >= 65 and byte <= 90 then
            byte = byte + 32
        end
        table.insert(parts, string.char(byte))
        index = index + 1
    end
    return table.concat(parts)
end

local function ReplaceQuestToken(text, pattern, value, lower)
    if not string.find(text, pattern) then
        return text, true
    end
    if type(value) ~= "string" or value == "" then
        return text, false
    end
    if lower then
        -- C-locale string.lower can corrupt UTF-8 continuation bytes on this
        -- client. Fold ASCII only, exactly like UQ.NameKey does.
        value = LowerASCII(value)
    end
    return string.gsub(text, pattern, function() return value end), true
end

local function FormatQuestText(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    local rendered, ok = ReplaceQuestToken(text, "%$[Nn]",
        UQ.Client and UQ.Client.GetPlayerName and UQ.Client.GetPlayerName())
    if not ok then return nil end
    rendered, ok = ReplaceQuestToken(rendered, "%$[Cc]",
        UQ.Client and UQ.Client.GetPlayerClass and UQ.Client.GetPlayerClass(), true)
    if not ok then return nil end
    rendered, ok = ReplaceQuestToken(rendered, "%$[Rr]",
        UQ.Client and UQ.Client.GetPlayerRace and UQ.Client.GetPlayerRace(), true)
    if not ok then return nil end
    rendered = string.gsub(rendered, "%$[Bb]", "\n")

    if string.find(rendered, "%$[Gg]") then
        local sex = UQ.Client and UQ.Client.GetPlayerSex and UQ.Client.GetPlayerSex()
        if sex ~= 2 and sex ~= 3 then
            return nil
        end
        rendered = string.gsub(rendered, "%$[Gg]([^:;]+):([^;]+);",
            function(male, female)
                if sex == 3 then
                    return female
                end
                return male
            end)
    end

    -- A known token left behind is malformed; any other $letter token is a
    -- database dialect this formatter does not understand. Both cases fail
    -- closed to the live client text.
    if string.find(rendered, "%$[A-Za-z]") then
        return nil
    end
    return rendered
end

-- Exact translated T/O/D field for presentation. The internal setting name
-- predates the description/objectives support and is retained so existing
-- SavedVariables keep their opt-out. Identity and matching never call this.
function Database:GetQuestDisplayText(questOrId, field, fallbackText)
    if field ~= "T" and field ~= "O" and field ~= "D" then
        return fallbackText
    end

    local questId = questOrId
    local liveText = fallbackText
    if type(questOrId) == "table" then
        questId = questOrId.questId
        if field == "T" then
            liveText = questOrId.title or fallbackText
        end
    end
    if type(liveText) ~= "string" or liveText == "" then
        liveText = nil
    end

    local config = UQ:GetModule("Config")
    local translate = not config or config:Get("translateQuestTitles") ~= false
    local language = UQ.GetLanguage and UQ.GetLanguage()
    if translate and type(questId) == "number" and type(language) == "string" then
        -- The selected language already matches the client: its live text is
        -- newer, already token-expanded, and may contain realm-specific edits.
        if not liveText or language ~= locale then
            local row = self:GetQuestTextForLanguage(questId, language)
            local translated = row and row[field]
            translated = FormatQuestText(translated)
            if translated then
                if UQ.PrepareTranslatedGameText then
                    translated = UQ.PrepareTranslatedGameText(translated, language)
                end
                return translated
            end
        end
    end
    return liveText
end

-- The one title policy used by every addon-owned presentation. `questOrId`
-- may be a live QuestState row or a numeric database ID (available-quest
-- markers have no live row yet). The live title always wins when translation
-- is disabled, when the selected language already is the client language, or
-- when no exact translated row exists. That preserves server-edited titles
-- and makes unmatched/ambiguous quests degrade to precisely what the client
-- showed rather than to a database guess.
function Database:GetQuestDisplayTitle(questOrId, fallbackTitle)
    local translated = self:GetQuestDisplayText(questOrId, "T", fallbackTitle)
    if translated then
        return translated
    end
    local questId = type(questOrId) == "table" and questOrId.questId or questOrId
    if type(questId) == "number" then
        return self:GetQuestTitle(questId)
    end
    return fallbackTitle
end

-- Presentation modules call one helper rather than each reimplementing the
-- fallback chain. The adapter remains the only code that knows the bundled
-- locale-table shapes.
function UQ.GetQuestDisplayTitle(questOrId, fallbackTitle)
    local database = UQ:GetModule("Database")
    if database and type(database.GetQuestDisplayTitle) == "function" then
        return database:GetQuestDisplayTitle(questOrId, fallbackTitle)
    end
    if type(questOrId) == "table" then
        return questOrId.title or fallbackTitle
    end
    return fallbackTitle
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

-- Whether every active Vanilla 1.12.1 spawn of this creature is on a dungeon
-- or raid map. Database/instance_only_units.lua is generated from the source
-- VMaNGOS creature.map values; a creature with any outdoor or uncertain spawn
-- is deliberately absent. This provenance test replaces all entrance-radius
-- guesses for both alerts and Rare/Elite/Boss map pins.
function Database:IsInstanceOnlyUnit(unitId)
    if not db or type(db.instance_only_units) ~= "table"
        or type(unitId) ~= "number" then
        return false
    end
    return type(db.instance_only_units[unitId]) == "table"
end

-- Area-specific entrance-cave creatures promoted from the player's reviewed
-- map-pin collection. The stored coordinate is provenance for later audits;
-- membership is the runtime decision. Unlike IsInstanceOnlyUnit, this must
-- keep the outdoor area in the key because the same creature may be valid in
-- another zone.
function Database:IsDungeonApproachUnit(unitId, areaId)
    if not db or type(db.dungeon_approach_units) ~= "table"
        or type(unitId) ~= "number" or type(areaId) ~= "number" then
        return false
    end
    local area = db.dungeon_approach_units[areaId]
    return type(area) == "table" and type(area[unitId]) == "table"
end

-- Temporary player-reviewed dungeon-approach collection. The key is scoped
-- to an area because a creature ID may also have legitimate outdoor spawns in
-- another zone. The value records the representative map coordinate for the
-- later data review, but membership alone decides runtime suppression.
function Database:IsManuallyIgnoredRankedUnit(unitId, areaId)
    if type(unitId) ~= "number" or type(areaId) ~= "number" then
        return false
    end
    local config = UQ:GetModule("Config")
    local section = config and config:GetSection("rareApproachIgnores")
    if type(section) ~= "table" then
        return false
    end
    local key = tostring(unitId) .. ":" .. tostring(areaId)
    return section[key] ~= nil
end

-- One shared answer for the map and alert. Source-confirmed instance-only
-- creatures are global; bundled and newly reviewed approach creatures are
-- area-specific.
function Database:IsRankedUnitSuppressed(unitId, areaId)
    return self:IsInstanceOnlyUnit(unitId)
        or self:IsDungeonApproachUnit(unitId, areaId)
        or self:IsManuallyIgnoredRankedUnit(unitId, areaId)
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

function Database:GetAreaTrigger(triggerId)
    if not db or type(db.areatrigger) ~= "table" then
        return nil
    end
    return db.areatrigger[triggerId]
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

-- The area a subzone is placed onto, or nil for an area the table files under
-- nothing.
--
-- Database/zones.lua is keyed by the SUBZONE's own area ID and its first field
-- is the parent: [9] Northshire Valley -> 12 Elwynn Forest, [154] Deathknell
-- -> 85 Tirisfal Glades, [113] Gold Coast Quarry -> 40 Westfall. Top-level
-- zones are simply absent from it (Elwynn Forest, Tirisfal Glades, Ironforge),
-- and the five city maps that carry no parent record 0 rather than an area, so
-- 0 is rejected here alongside a missing row.
--
-- Coverage is partial by nature: 526 of the 1081 named areas have a row, so a
-- cave or an inn the client can still name ("Brill Town Hall", area 2118)
-- resolves to nothing here. Callers must handle nil rather than assume a
-- parent exists for every place the player can stand.
function Database:GetParentZoneId(zoneId)
    local transform = self:GetZoneTransform(zoneId)
    local parentId = transform and transform[1]
    if type(parentId) ~= "number" or parentId <= 0 or parentId == zoneId then
        return nil
    end
    return parentId
end

-- Zone width and height in yards, needed for minimap-relative distance work.
function Database:GetZoneYards(zoneId)
    if not db or type(db.minimap) ~= "table" then
        return nil
    end
    return db.minimap[zoneId]
end

-- Dungeon entrances ---------------------------------------------------------
--
-- Database/instances.lua names every Vanilla dungeon and raid and points each
-- of its entrances at an areatrigger; Database/areatrigger.lua carries that
-- trigger's coordinate. Resolving the two gives 46 entrance points over 23
-- areas -- Blackfathom Deeps' door is recorded in both Darkshore and
-- Ashenvale, and Uldaman's in both Badlands and Loch Modan, which is why this
-- is indexed per area and not per instance.
--
-- Returns normalized entrance locations for one area, or nil. Every location
-- keeps x/y at [1]/[2] and also carries the fields the finder consumes:
-- category, name, instanceType, sourceId and entranceLabel.
-- Built on the first ask and kept: both tables it reads are static for the
-- session. The returned list belongs to the index and must be treated as
-- read-only.
function Database:GetInstanceEntrances(areaId)
    if not self.instanceEntranceIndex then
        local index = {}
        self.instanceEntranceIndex = index
        local instances = db and db.instances
        if type(instances) == "table" then
            local mapId, record
            for mapId, record in pairs(instances) do
                local entrances = nil
                if type(record) == "table" then
                    entrances = record.entrances
                end
                if type(entrances) == "table" then
                    local entranceIndex = 1
                    local entranceTotal = table.getn(entrances)
                    while entranceIndex <= entranceTotal do
                        local entrance = entrances[entranceIndex]
                        local trigger = nil
                        if type(entrance) == "table" then
                            trigger = entrance.trigger
                        end
                        local triggerRecord = nil
                        if type(trigger) == "number" then
                            triggerRecord = self:GetAreaTrigger(trigger)
                        end
                        local coords = nil
                        if type(triggerRecord) == "table" then
                            coords = triggerRecord.coords
                        end
                        -- Blackwing Lair's internal area trigger has no map
                        -- coordinate. instances.lua names its exterior access
                        -- trigger explicitly, so use that point only when the
                        -- entrance trigger itself cannot be projected.
                        if (type(coords) ~= "table" or table.getn(coords) == 0)
                            and type(record.access_trigger) == "number" then
                            triggerRecord = self:GetAreaTrigger(record.access_trigger)
                            if type(triggerRecord) == "table" then
                                coords = triggerRecord.coords
                            end
                        end
                        if type(coords) == "table" then
                            local coordIndex = 1
                            local coordTotal = table.getn(coords)
                            while coordIndex <= coordTotal do
                                local coordinate = coords[coordIndex]
                                if type(coordinate) == "table"
                                    and type(coordinate[1]) == "number"
                                    and type(coordinate[2]) == "number"
                                    and type(coordinate[3]) == "number" then
                                    local bucket = index[coordinate[3]]
                                    if not bucket then
                                        bucket = {}
                                        index[coordinate[3]] = bucket
                                    end
                                    local name = record.name
                                    if type(name) ~= "string" or name == "" then
                                        name = tostring(mapId)
                                    end
                                    local entranceLabel = entrance.label
                                    local displayName = name
                                    if type(entranceLabel) == "string"
                                        and entranceLabel ~= "" then
                                        displayName = displayName .. " (" .. entranceLabel .. ")"
                                    end
                                    table.insert(bucket, {
                                        coordinate[1], coordinate[2],
                                        category = "instances",
                                        x = coordinate[1],
                                        y = coordinate[2],
                                        areaId = coordinate[3],
                                        sourceType = "instance",
                                        sourceId = mapId,
                                        name = displayName,
                                        instanceType = record.type,
                                        minimumLevel = record.min,
                                        entranceLabel = entranceLabel,
                                    })
                                end
                                coordIndex = coordIndex + 1
                            end
                        end
                        entranceIndex = entranceIndex + 1
                    end
                end
            end
        end
    end
    if type(areaId) ~= "number" then
        return nil
    end
    return self.instanceEntranceIndex[areaId]
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

    -- ONE pin per creature per area, for the Rare/Elite/Boss row.
    --
    -- The bundled data records every spawn point a creature has, and for a
    -- roamer that is its whole patrol: Hogger carries five coordinates in
    -- Elwynn Forest and was drawn five times (reported 2026-08-28). A player
    -- reading the map wants to know Hogger is there, once.
    --
    -- The point chosen is the MEDOID -- the recorded coordinate closest to the
    -- average of them all -- and not the average itself. A centroid is a place
    -- the data never claimed anything stands: with spawns around a lake or a
    -- ridge it lands in the water or inside the rock. The medoid is always a
    -- real recorded spawn, and it sits in the middle of the cluster rather
    -- than on its edge the way "the first coordinate" would.
    --
    -- Measured over the 420 (creature, area) pairs that have more than one
    -- spawn: half sit within 4.4% of the zone of their centre and 90% within
    -- 18.3%, so for most of them the choice barely matters. 106 are spread
    -- over more than 10% of the zone -- those are creatures with two genuinely
    -- separate camps, where one pin necessarily names one of them.
    local function AppendMedoid(category, rawId, detail)
        if type(rawId) ~= "number" or rawId < 0 then
            return
        end
        if self:IsInstanceOnlyUnit(rawId) then
            return
        end
        local entity = self:GetUnit(rawId)
        if type(entity) ~= "table" or type(entity.coords) ~= "table" then
            return
        end

        local sumX, sumY, count = 0, 0, 0
        local index = 1
        local total = table.getn(entity.coords)
        while index <= total do
            local coordinate = entity.coords[index]
            if type(coordinate) == "table" and coordinate[3] == areaId
                and type(coordinate[1]) == "number" and type(coordinate[2]) == "number" then
                sumX = sumX + coordinate[1]
                sumY = sumY + coordinate[2]
                count = count + 1
            end
            index = index + 1
        end
        if count == 0 then
            return
        end
        local centreX, centreY = sumX / count, sumY / count

        local best, bestX, bestY
        index = 1
        while index <= total do
            local coordinate = entity.coords[index]
            if type(coordinate) == "table" and coordinate[3] == areaId
                and type(coordinate[1]) == "number" and type(coordinate[2]) == "number" then
                local dx = coordinate[1] - centreX
                local dy = coordinate[2] - centreY
                local squared = dx * dx + dy * dy
                if not best or squared < best then
                    best = squared
                    bestX = coordinate[1]
                    bestY = coordinate[2]
                end
            end
            index = index + 1
        end

        local name = self:GetUnitName(rawId)
        table.insert(locations, {
            category = category,
            x = bestX,
            y = bestY,
            areaId = areaId,
            sourceType = "unit",
            sourceId = rawId,
            name = type(name) == "string" and name or category,
            detail = detail,
            spawnCount = count,
        })
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
            -- "rares" is the one node category that is NOT a meta relation any
            -- more: the row covers every ranked creature, not the curated 409.
            local relation = meta[category]
            if category == "rares" then
                relation = self:GetRankedMobRelation()
            end
            if type(wanted) == "table" and wanted[category] and type(relation) == "table" then
                local rawId, value
                for rawId, value in pairs(relation) do
                    -- The meta value doubles as the detail: a positive number
                    -- is a skill or a level, a string is a faction token.
                    if category == "rares" then
                        AppendMedoid(category, rawId,
                            type(value) == "number" and value > 0 and value or nil)
                    elseif type(value) == "number" and value > 0 then
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
    local requirementItems = {}
    local relation = self:GetQuestObjectiveSources(questId)
    if type(relation) ~= "table" or type(relation.IR) ~= "table" then
        questItemUseTargetCache[questId] = targets
        questItemUseRequirementCache[questId] = requirementItems
        return targets
    end

    local requirements = db["quests-itemreq"]
    local _, itemId
    for _, itemId in pairs(relation.IR) do
        local uses = type(itemId) == "number" and requirements[itemId]
        if type(uses) == "table" then
            -- Recorded only for an item whose use target actually resolves.
            -- An obj.IR entry the itemreq table does not know about is left
            -- alone: without a target there is nothing to be a means TO, and
            -- demoting it would hide a step rather than reclassify one.
            requirementItems[itemId] = true
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
    questItemUseRequirementCache[questId] = requirementItems
    return targets
end

-- The obj.I items that GetQuestItemUseTargets classified as means rather than
-- objectives, as a set keyed by item ID. Read-only: callers must not mutate it.
--
-- An obj.IR item is something the quest has the player USE, not something the
-- quest counts. Its own source creatures are therefore not objective targets
-- either -- they are where the tool is picked up. Quest 1136 (Frostmaw) is the
-- reference case: obj.I names both the Fresh Carcass and Frostmaw's Mane, but
-- only the Mane is an objective. The Carcass is bait, dropped by four Mountain
-- Lion species with 73 spawns in Alterac and 99 in Hillsbrad, so expanding it
-- like an ordinary item objective buried the quest's actual target -- Frostmaw
-- himself, one summon coordinate -- under a hundred identical dots.
--
-- The bait still has to be findable, so this does not delete those locations:
-- it moves them onto the same conditional path the use target already takes
-- (Data/QuestTarget.lua, AppendItemUseLocations), where the live bag decides
-- which half of the step is on screen.
function Database:GetQuestItemUseRequirementItems(questId)
    -- The cache is filled as a side effect of the targets walk, which is the
    -- only place the classification is made.
    self:GetQuestItemUseTargets(questId)
    return questItemUseRequirementCache[questId] or {}
end

-- Where the items of GetQuestItemUseRequirementItems are obtained, in the same
-- row shape GetQuestLocations produces. Appended by the map layer only while
-- the bags say the item is not already carried, so a player holding the bait
-- stops being shown where to farm more of it.
function Database:GetQuestItemUseSourceLocations(questId, itemId, areaId, limit)
    local locations = {}
    if not db or type(itemId) ~= "number" or type(areaId) ~= "number" then
        return locations
    end
    if not self:GetQuestItemUseRequirementItems(questId)[itemId] then
        return locations
    end
    local item = self:GetItem(itemId)
    if type(item) ~= "table" then
        return locations
    end

    local function AppendSources(sourceType, sources)
        if type(sources) ~= "table" then
            return
        end
        local sourceId
        for sourceId in pairs(sources) do
            local found = self:GetEntityLocations(sourceType, sourceId, areaId, limit)
            local index = 1
            local total = table.getn(found)
            while index <= total and (not limit or table.getn(locations) < limit) do
                table.insert(locations, found[index])
                index = index + 1
            end
        end
    end

    AppendSources("unit", item.U)
    AppendSources("object", item.O)
    return locations
end

-- Bought objectives ---------------------------------------------------------
-- A quest item is not always killed for or looted. Some are simply sold: the
-- Refreshing Spring Water of "Give Gerard a Drink", the Coarse Thread of
-- "Kodo Hide Bag", the Skin of Sweet Rum of "Dry Times". The bundled item
-- record carries that as its own relation -- items[id].V maps a vendor unit
-- to the stock limit it keeps (0 = unlimited) -- and GetQuestLocations
-- deliberately does not walk it: a vendor is not where the objective happens,
-- it is where the objective is bought, so folding its coordinates into the
-- objective cloud would put a blue area over a shopkeeper and drag the
-- quest's single point towards him.
--
-- Both objective item relations are read. `obj.I` is the ordinary "bring me
-- N of these" case and is almost all of it; `obj.IR` is the item-use case
-- (see GetQuestItemUseTargets), where the item still has to be obtained
-- before it can be used on anything, and two bundled quests buy it.
--
-- Returns a list of { itemId, itemName, unitId, unitName, faction }, ordered
-- by item and then by unit ID so the same quest always produces the same
-- list. Coordinates are deliberately NOT resolved here: the caller knows
-- which area it is drawing and asks GetEntityLocations for that one.
function Database:GetQuestVendorTargets(questId)
    local targets = {}
    if not db or type(questId) ~= "number" then
        return targets
    end
    local cached = questVendorTargetCache[questId]
    if cached then
        return cached
    end
    local relation = self:GetQuestObjectiveSources(questId)
    if type(relation) ~= "table" then
        questVendorTargetCache[questId] = targets
        return targets
    end

    local seenItem = {}

    local function AppendItem(itemId)
        if type(itemId) ~= "number" or seenItem[itemId] then
            return
        end
        seenItem[itemId] = true
        local item = self:GetItem(itemId)
        if type(item) ~= "table" or type(item.V) ~= "table" then
            return
        end
        local itemName = self:GetItemName(itemId)
        -- pairs order is a hash order, and this list ends up deciding which
        -- vendors survive a pin budget, so it is sorted before it is handed
        -- out rather than shuffling between two identical rebuilds.
        local unitIds = {}
        local unitId
        for unitId in pairs(item.V) do
            if type(unitId) == "number" then
                table.insert(unitIds, unitId)
            end
        end
        table.sort(unitIds)
        local index = 1
        local total = table.getn(unitIds)
        while index <= total do
            local id = unitIds[index]
            local unit = self:GetUnit(id)
            -- A vendor with no recorded spawn cannot be drawn anywhere, so it
            -- is dropped here instead of costing every caller a lookup.
            if type(unit) == "table" and type(unit.coords) == "table" then
                table.insert(targets, {
                    itemId = itemId,
                    itemName = itemName,
                    unitId = id,
                    unitName = self:GetUnitName(id),
                    faction = unit.fac,
                })
            end
            index = index + 1
        end
    end

    -- Sorted for the same reason the unit IDs are: a hash order here would
    -- let two rebuilds spend the caller's pin budget on different items.
    local itemIds = {}
    local _, itemId
    if type(relation.I) == "table" then
        for _, itemId in pairs(relation.I) do
            if type(itemId) == "number" then table.insert(itemIds, itemId) end
        end
    end
    if type(relation.IR) == "table" then
        for _, itemId in pairs(relation.IR) do
            if type(itemId) == "number" then table.insert(itemIds, itemId) end
        end
    end
    table.sort(itemIds)
    local itemIndex = 1
    local itemTotal = table.getn(itemIds)
    while itemIndex <= itemTotal do
        AppendItem(itemIds[itemIndex])
        itemIndex = itemIndex + 1
    end

    questVendorTargetCache[questId] = targets
    return targets
end

-- Builds the complete list of direct database coordinates for one active
-- quest in one area. Passing a numeric limit remains available to callers
-- that intentionally render a bounded non-objective surface such as turn-ins.
-- Item objectives are expanded through their unit/object source tables, and
-- exploration objectives through their area-trigger records, so the map layer
-- never depends on the generated data shapes.
-- Coordinates in child areas are deliberately excluded until transforms are
-- runtime-verified; this first map slice is current-zone-only.
--
-- Item-use targets (see GetQuestItemUseTargets) are excluded from the
-- objective pass entirely. They are not unconditional objective sources, and
-- the map layer adds them back through GetEntityLocations once it knows the
-- required item is carried. The items those steps consume are excluded on the
-- same grounds -- see GetQuestItemUseRequirementItems -- and the map layer adds
-- their sources back through GetQuestItemUseSourceLocations while the bags say
-- the item is still to be found.
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
    --
    -- The items those steps consume are held back the same way, but they need
    -- their own set rather than a `visited` seed: what has to be skipped is the
    -- obj.I entry itself, before it expands into the creatures that drop it.
    -- See GetQuestItemUseRequirementItems for why bait is not an objective.
    local requirementItems = {}
    if not isComplete then
        local targets = self:GetQuestItemUseTargets(questId)
        local targetIndex = 1
        local targetTotal = table.getn(targets)
        while targetIndex <= targetTotal do
            local target = targets[targetIndex]
            visited[target.sourceType .. tostring(target.sourceId)] = true
            targetIndex = targetIndex + 1
        end
        requirementItems = self:GetQuestItemUseRequirementItems(questId)
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
            elseif sourceType == "object" then
                AppendEntity(sourceType, sourceId, self:GetObject(sourceId))
            elseif sourceType == "areaTrigger" then
                AppendEntity(sourceType, sourceId, self:GetAreaTrigger(sourceId))
            end
        end
    end

    AppendRelationSources("unit", relation.U)
    AppendRelationSources("object", relation.O)
    AppendRelationSources("areaTrigger", relation.A)

    if type(relation.I) == "table" then
        local _, itemId
        for _, itemId in pairs(relation.I) do
            if limit and table.getn(locations) >= limit then
                break
            end
            local item = not requirementItems[itemId] and self:GetItem(itemId)
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
-- coordinate in, WITHOUT GetQuestLocations' current-zone filter. It answers a
-- question a pin cannot: which zone(s) does the static data say this quest's
-- objectives or turn-in are actually in, whatever the map happens to be
-- showing. Callers use it both to NAME the zone to travel to and to take the
-- world map there (Map/MapContext.lua ShowAreas). Same relation-walking shape
-- as GetQuestLocations (unit/object/area-trigger direct sources, plus item
-- sources), traversed the same way so the two can never disagree about what
-- "this quest's locations" means.
--
-- Ordered most-recorded-spawns first, then by area id. The walk itself reaches
-- the relation tables through `pairs`, whose order Lua does not define, so
-- without this the list came back in a different order run to run -- fine
-- while the only consumer joined the names into one sentence, not fine now
-- that the first entry decides which zone the map is taken to. Spawn count is
-- the tiebreak rather than something arbitrary because a quest whose mobs are
-- mostly in one zone and stray into a second should open the first.
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

    local counts = {}
    local areaIds = {}

    local function AppendAreasFrom(record)
        if type(record) ~= "table" or type(record.coords) ~= "table" then
            return
        end
        local index = 1
        local total = table.getn(record.coords)
        while index <= total do
            local coordinate = record.coords[index]
            local coordinateArea = type(coordinate) == "table" and coordinate[3]
            if type(coordinateArea) == "number" then
                if not counts[coordinateArea] then
                    counts[coordinateArea] = 0
                    table.insert(areaIds, coordinateArea)
                end
                counts[coordinateArea] = counts[coordinateArea] + 1
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
            elseif sourceType == "object" then
                AppendAreasFrom(self:GetObject(sourceId))
            elseif sourceType == "areaTrigger" then
                AppendAreasFrom(self:GetAreaTrigger(sourceId))
            end
        end
    end

    AppendRelationSources("unit", relation.U)
    AppendRelationSources("object", relation.O)
    AppendRelationSources("areaTrigger", relation.A)

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

    table.sort(areaIds, function(left, right)
        if counts[left] ~= counts[right] then
            return counts[left] > counts[right]
        end
        return left < right
    end)

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
    elseif sourceType == "areaTrigger" then
        record = self:GetAreaTrigger(sourceId)
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

-- Rank index ---------------------------------------------------------------
-- Rare, rare-elite, boss and elite creatures, bucketed by the area their
-- spawns are recorded in. Built once, in chunks on the shared driver, and only
-- when something asks for it.

-- The ranks this index carries: all four of them, because two features read
-- it and they want different subsets.
--
-- `Map/NpcPins.lua` draws the whole thing as its Rare/Elite/Boss layer. The
-- proximity alert (`World/RareAlert.lua`) narrows it with
-- `Database:IsAlertWorthy` below, because ALERTING off rank alone is wrong:
-- rank 1 is 816 ordinary elites, every elite camp in the game plus a tail of
-- parked NPCs that are elite for reasons unrelated to being worth hunting.
-- Silas Darkmoon, the Darkmoon Faire barker, is rank 1, level 61, with a
-- recorded spawn in Goldshire, and alerting off rank put him in front of a
-- level-8 player in Elwynn Forest (reported 2026-08-28). Drawing him on a map
-- the player chose to open is fine; interrupting them with a sound is not.
local RANK_ELITE = 1
local RANK_RARE_ELITE = 2
local RANK_BOSS = 3
local RANK_RARE = 4

-- Every rank the data defines. This is only "is this string a rank at all";
-- it decides nothing about alerting.
local KNOWN_RANK = {
    [RANK_ELITE] = true,
    [RANK_RARE_ELITE] = true,
    [RANK_BOSS] = true,
    [RANK_RARE] = true,
}

-- Ranks the ALERT admits on rank alone. Deliberately just the boss rank --
-- 28 creatures with world coordinates, the open-world bosses; everything else
-- it alerts on has to be named by the curated `meta.rares` list (409 entries:
-- exactly the 272 rank-4 rares plus the 137 rank-2 rare elites, no ordinary
-- elites and no bosses), which is the same list the NPC finder's rare row drew
-- before it was widened to every rank.
local ALERT_RANKED = {
    [RANK_BOSS] = true,
}

local function IsCuratedRare(unitId)
    local meta = db and db.meta
    local rares = meta and meta["rares"]
    return type(rares) == "table" and rares[unitId] ~= nil
end

-- WHAT IS NOT A MOB, EVEN WITH A RANK ON IT
-- ------------------------------------------
-- Two filters, both structural, both measured against the bundled data. They
-- exist because a rank says how hard something hits, not whether anybody would
-- ever fight it.
--
-- 1. A `fac` TOKEN MEANS IT BELONGS TO A PLAYER FACTION.
--
--    Every one of the 33 ranked creatures with coordinates in Orgrimmar
--    carries one -- the grunts, the officers, the trainers, Thrall and Vol'jin
--    (rank 3, so they were even reaching the proximity alert). They filled the
--    capital's map with pins for things no one hunts (reported 2026-08-28).
--    Across the whole dataset the split is clean: 362 rank-1 and 12 rank-3
--    creatures carry a faction token, while Hogger, Mor'Ladim, King Bangalash
--    and the other 454 real elites carry none.
--
--    The curated `meta.rares` list overrides this: 18 creatures it names do
--    carry a token, and a human calling something a rare mob outranks an
--    inference drawn from one field.
--
-- 2. SPAWNS IN EXACTLY ELWYNN FOREST AND MULGORE MEAN THE DARKMOON FAIRE.
--
--    Those are the faire's two rotation sites in this data, on opposite
--    continents, and nothing native lives in both. The signature selects 22
--    creatures and every one of them is faire staff -- Sayge, Rinling, Flik's
--    Frog, the carnies -- of which two are ranked: Silas Darkmoon (elite,
--    level 61, which is what put a level-61 elite in front of a level-8 player
--    in Elwynn) and Felinni. It catches nothing else, so it is a rule rather
--    than a list of IDs to keep in sync.
--
--    This does not generalise to other holidays: the Lunar Festival's ranked
--    NPCs are already gone via their faction token, and no other event in the
--    bundled data moves between fixed sites.
local FAIRE_AREA_A = 12       -- Elwynn Forest
local FAIRE_AREA_B = 215      -- Mulgore

local function IsTravellingFaire(record)
    local coords = record.coords
    if type(coords) ~= "table" then
        return false
    end
    local sawA, sawB = false, false
    local index = 1
    local total = table.getn(coords)
    while index <= total do
        local coordinate = coords[index]
        local areaId = type(coordinate) == "table" and coordinate[3] or nil
        if type(areaId) == "number" then
            if areaId == FAIRE_AREA_A then
                sawA = true
            elseif areaId == FAIRE_AREA_B then
                sawB = true
            else
                -- A third zone means it lives somewhere of its own.
                return false
            end
        end
        index = index + 1
    end
    return sawA and sawB
end

-- Whether a ranked creature is something a player would actually hunt. Both
-- the NPC finder's Rare/Elite/Boss row and the proximity alert are built on
-- this, so a city guard cannot appear on one and not the other.
local function IsMobRecord(unitId, record)
    if type(record) ~= "table" then
        return false
    end
    if IsCuratedRare(unitId) then
        return true
    end
    if type(record.fac) == "string" and record.fac ~= "" then
        return false
    end
    return not IsTravellingFaire(record)
end

-- `rnk` is stored as a STRING in the bundled data, exactly like `lvl` is (see
-- docs/WORLD-DATA-NOTES.md). Every read of it goes through here so no caller
-- can compare it against a number and silently match nothing.
--
-- This answers the creature's rank whatever it is, so the alert can SAY
-- "Rare Elite" or "Boss". Whether the creature is alerted about at all is
-- Database:IsAlertWorthy below, which is a different question.
function Database:GetUnitRank(unitId)
    local record = self:GetUnit(unitId)
    if type(record) ~= "table" then
        return nil
    end
    local rank = tonumber(record.rnk)
    if not rank or not KNOWN_RANK[rank] then
        return nil
    end
    return rank
end

-- Whether a creature is a huntable mob at all: ranked, and not one of the
-- things IsMobRecord above rules out. This is what the rank index admits, so
-- it is the set the NPC finder's Rare/Elite/Boss row draws.
function Database:IsMob(unitId)
    local record = self:GetUnit(unitId)
    if type(record) ~= "table" then
        return false
    end
    local rank = tonumber(record.rnk)
    if not rank or not KNOWN_RANK[rank] then
        return false
    end
    return IsMobRecord(unitId, record)
end

-- Whether a creature is worth INTERRUPTING the player for: a mob, and either
-- named by the curated `meta.rares` list or a boss. Narrower than IsMob on
-- purpose -- drawing an ordinary elite on a map the player chose to open is
-- fine, playing a sound at them for one is not.
function Database:IsAlertWorthy(unitId)
    if self:IsInstanceOnlyUnit(unitId) or not self:IsMob(unitId) then
        return false
    end
    if IsCuratedRare(unitId) then
        return true
    end
    local record = self:GetUnit(unitId)
    local rank = type(record) == "table" and tonumber(record.rnk) or nil
    return rank ~= nil and ALERT_RANKED[rank] == true
end

-- Every ranked creature as a service-style relation, unitId -> level, for the
-- NPC finder's Rare/Elite/Boss row. `meta.rares` carries a curated level for
-- the 409 it names; everything else takes the level off the unit record, where
-- `lvl` is a string and may be a range ("24-25") -- the first number in it is
-- what a numeric detail can carry, and 0 stands for "no level in the data".
--
-- Built once and kept: it is a projection of tables that never change during a
-- session.
function Database:GetRankedMobRelation()
    if self.rankedMobRelation then
        return self.rankedMobRelation
    end
    local relation = {}
    self.rankedMobRelation = relation
    local units = db and db.units
    if type(units) ~= "table" then
        return relation
    end
    local meta = db.meta
    local curated = type(meta) == "table" and meta["rares"] or nil

    local unitId, record
    for unitId, record in pairs(units) do
        if type(record) == "table" then
            local rank = tonumber(record.rnk)
            if rank and KNOWN_RANK[rank] and IsMobRecord(unitId, record)
                and not self:IsInstanceOnlyUnit(unitId) then
                local level = type(curated) == "table" and tonumber(curated[unitId]) or nil
                if not level then
                    local _, _, first = string.find(tostring(record.lvl or ""), "^(%d+)")
                    level = tonumber(first) or 0
                end
                relation[unitId] = level
            end
        end
    end
    return relation
end

-- Asks for the index. Safe to call repeatedly; the first call schedules the
-- chunked build and later ones are free.
function Database:StartRankIndex()
    if not self.available or self.rankIndexRequested then
        return self.rankIndexReady
    end
    self.rankIndexRequested = true
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("database.rankindex", 0, function() Database:IndexRankChunk() end)
    end
    return self.rankIndexReady
end

function Database:IndexRankChunk()
    if not self.available or self.rankIndexReady then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("database.rankindex")
        end
        return
    end

    if not self.areaRankIndex then
        self.areaRankIndex = {}
    end

    local units = db and db.units
    if type(units) ~= "table" then
        self.rankIndexReady = true
        return
    end

    local processed = 0
    while processed < INDEX_CHUNK do
        local unitId, record = next(units, rankIndexCursor)
        if unitId == nil then
            self.rankIndexReady = true
            UQ:Debug("rank index complete: " .. self.rankedUnitCount .. " creatures")
            local driver = UQ:GetModule("Driver")
            if driver then
                driver:Unschedule("database.rankindex")
            end
            return
        end
        rankIndexCursor = unitId

        if type(record) == "table" and type(record.coords) == "table" then
            local rank = tonumber(record.rnk)
            if rank and KNOWN_RANK[rank] and IsMobRecord(unitId, record)
                and not self:IsInstanceOnlyUnit(unitId) then
                -- One entry per (creature, area), not per spawn point: a rare
                -- with four recorded spawns in one zone is one creature the
                -- player can be near, and the alert names the creature.
                local perArea = nil
                local coords = record.coords
                local index = 1
                local total = table.getn(coords)
                while index <= total do
                    local coordinate = coords[index]
                    if type(coordinate) == "table" and type(coordinate[1]) == "number"
                        and type(coordinate[2]) == "number"
                        and type(coordinate[3]) == "number" then
                        local areaId = coordinate[3]
                        if not perArea then
                            perArea = {}
                        end
                        local entry = perArea[areaId]
                        if not entry then
                            entry = { unitId = unitId, rank = rank, coords = {} }
                            perArea[areaId] = entry
                            local bucket = self.areaRankIndex[areaId]
                            if not bucket then
                                bucket = {}
                                self.areaRankIndex[areaId] = bucket
                            end
                            table.insert(bucket, entry)
                        end
                        table.insert(entry.coords, coordinate)
                    end
                    index = index + 1
                end
                if perArea then
                    self.rankedUnitCount = self.rankedUnitCount + 1
                end
            end
        end

        processed = processed + 1
    end
end

function Database:IsRankIndexReady()
    return self.rankIndexReady
end

-- Every ranked creature with a spawn recorded in areaId. The returned array
-- and the entries in it belong to the index and must be treated as read-only.
function Database:GetAreaRankedUnits(areaId)
    if not self.areaRankIndex or type(areaId) ~= "number" then
        return nil
    end
    return self.areaRankIndex[areaId]
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
