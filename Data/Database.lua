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

-- Native reward items expose a name but no dependable item ID on this
-- client. Build a client-locale name -> item ID index incrementally so a
-- quest panel can reach the same item's exact translated name without a
-- synchronous walk of the full item table when the window opens.
Database.itemNameIndex = nil
Database.itemNameIndexReady = false
Database.itemNameIndexedCount = 0

-- Hover identity on this client is the tooltip's rendered name, not an entity
-- ID. Build the name-to-duration join incrementally so the first tooltip does
-- not synchronously walk both complete world tables.
Database.respawnIndex = {}
Database.respawnIndexReady = false
Database.respawnIndexRevision = 0
Database.respawnIndexedCount = 0

-- Static service locations are cached per area/class/faction after their
-- first request. The source tables never change during a session, and doing
-- the relation walk once keeps map refreshes allocation-light.
Database.serviceLocationCache = {}
Database.serviceLocationCacheCount = 0

-- Alphabetical creature rows for the settings search. Built only when the
-- player opens that tab: login and ordinary map refreshes never pay for a UI
-- index they may not use. The bundled unit tables do not change during a
-- session, so one sorted list serves every later query.
Database.mobSearchIndex = nil

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
Database.rankedUnitNameIndex = nil
Database.rankIndexReady = false
Database.rankIndexRequested = false
Database.rankedUnitCount = 0

-- areaId -> { entrance, ... }: every recorded dungeon and raid entrance in
-- that area, resolved from Database/instances.lua through the areatriggers it
-- names. Each entrance keeps x/y at [1]/[2] for the proximity reader and also
-- carries normalized metadata for the finder map layer. Built on demand by
-- Database:GetInstanceEntrances below.
Database.instanceEntranceIndex = nil

-- areaId -> instance map ID, built once from Database/instances.lua and the
-- English area names. See Database:GetInstanceMapForArea below.
Database.instanceAreaIndex = nil

local db = nil
local indexCursor = nil
local itemNameIndexCursor = nil
local giverIndexCursor = nil
local rankIndexCursor = nil
local respawnIndexCursor = nil
local respawnIndexSource = "unit"
local respawnObjectIds = {}
local respawnItemIds = {}
local respawnNodeCategoryIndex = 1

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

-- Same reasoning again, keyed by quest: which instance maps a quest has work
-- on is fixed by the bundled tables. Only the tracker's zone filter asks, and
-- only while the player is standing inside an instance, so the bound is a
-- guard against unbounded growth rather than a tuning knob.
local MAX_QUEST_INSTANCE_MAP_CACHE = 400
local questInstanceMapCache = {}
local questInstanceMapCacheCount = 0

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

-- And for the object half of the objective relation: which live objective
-- line each object the quest puts on the map belongs to. Same static walk over
-- the same immutable tables, asked for on every map rebuild.
local questObjectiveObjectLinkCache = {}

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
    questObjectiveObjectLinkCache = {}
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

-- Recorded gaps in the bundled data -----------------------------------------
-- The bundled tables are a reduction of what pfQuest packaged from VMaNGOS,
-- and a few quests lost their whole point in the packaging rather than in the
-- reduction: the relation that would place them was never in the upstream
-- table either. Proving Allegiance (409) is the reference case. Its only
-- recorded objective is Lillith Nefara (unit 1946), who is summoned and
-- therefore has an empty `coords` list, so the quest drew no marker anywhere
-- -- while the two things the player actually has to walk to, the Crate of
-- Candles and the altar the candle is lit on, sit in `objects` with exact
-- coordinates and no relation tying them to the quest.
--
-- Rather than hand-edit the bundled snapshot -- which must stay as packaged,
-- for the attribution in Database/CREDITS.md to mean anything -- the missing
-- relations are declared here and written into the loaded tables once, at
-- attach. Every consumer downstream then sees an ordinary item-use quest and
-- needs no special case: `obj.IR` names the item, `quests-itemreq` names what
-- it is used on (negative = game object, positive = creature), and
-- QuestTarget:AppendItemUseLocations already switches between "where to get
-- it" and "where to use it" as the bags and the objective lines change.
--
-- A fix only ever ADDS a relation the tables do not have. It never overwrites
-- a recorded one, so a later data sync that fills the gap upstream silently
-- wins over the entry here.
local DATA_FIXES = {
    {
        -- Proving Allegiance. Take a Candle of Beckoning from the Crate of
        -- Candles on Gunther's island (68.2/42.0 Tirisfal), light it on
        -- Lillith's Dinner Table on the islet south of it (66.6/44.9), kill
        -- what it summons.
        questId = 409,
        itemId = 3080,
        sourceObjectIds = { 1586 },
        useTargets = { -1557 },
    },
}

-- Writes one DATA_FIXES entry into the loaded tables. Silent on anything it
-- cannot justify: a quest, item or table the data does not have is a sign the
-- snapshot moved on, not something to fault over.
local function ApplyDataFix(fix)
    local quest = db.quests and db.quests[fix.questId]
    if type(quest) ~= "table" then
        return
    end

    if type(quest.obj) ~= "table" then
        quest.obj = {}
    end
    if type(quest.obj.IR) ~= "table" then
        quest.obj.IR = {}
    end
    local present = false
    local _, existing
    for _, existing in pairs(quest.obj.IR) do
        if existing == fix.itemId then
            present = true
        end
    end
    if not present then
        table.insert(quest.obj.IR, fix.itemId)
    end

    if type(db.items) == "table" then
        if type(db.items[fix.itemId]) ~= "table" then
            db.items[fix.itemId] = {}
        end
        local item = db.items[fix.itemId]
        if type(item.O) ~= "table" then
            item.O = {}
        end
        local index = 1
        local total = table.getn(fix.sourceObjectIds)
        while index <= total do
            local objectId = fix.sourceObjectIds[index]
            if item.O[objectId] == nil then
                item.O[objectId] = 100
            end
            index = index + 1
        end
    end

    if type(db["quests-itemreq"]) == "table" then
        local requirements = db["quests-itemreq"]
        if type(requirements[fix.itemId]) ~= "table" then
            requirements[fix.itemId] = {}
        end
        local index = 1
        local total = table.getn(fix.useTargets)
        while index <= total do
            local target = fix.useTargets[index]
            if requirements[fix.itemId][target] == nil then
                requirements[fix.itemId][target] = 0
            end
            index = index + 1
        end
    end
end

local function ApplyDataFixes()
    if not db or type(db.quests) ~= "table" then
        return
    end
    local index = 1
    local total = table.getn(DATA_FIXES)
    while index <= total do
        ApplyDataFix(DATA_FIXES[index])
        index = index + 1
    end
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
    -- Before anything reads the tables: the fixes are part of the dataset as
    -- far as every consumer is concerned.
    ApplyDataFixes()
    -- A new data table voids every walk cached against the old one.
    FlushQuestLocationCache()
    self.instanceEntranceIndex = nil
    self.mobSearchIndex = nil
    self.itemNameIndex = nil
    self.itemNameIndexReady = false
    self.itemNameIndexedCount = 0
    itemNameIndexCursor = nil
    self.respawnIndex = {}
    self.respawnIndexReady = false
    self.respawnIndexRevision = 0
    self.respawnIndexedCount = 0
    respawnIndexCursor = nil
    respawnIndexSource = "unit"
    respawnObjectIds = {}
    respawnItemIds = {}
    respawnNodeCategoryIndex = 1

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
        driver:Schedule("database.itemnames", 0, function() Database:IndexItemNameChunk() end)
        driver:Schedule("database.giverindex", 0, function() Database:IndexGiverChunk() end)
        driver:Schedule("database.respawnindex", 0, function() Database:IndexRespawnChunk() end)
    end
end

-- Raw table access ----------------------------------------------------------

function Database:GetQuest(questId)
    if not db then
        return nil
    end
    return db.quests[questId]
end

-- Quest rewards -------------------------------------------------------------
--
-- Both fields arrived with a later sync of Database/quests.lua (its own file
-- header records the VMaNGOS revision they came from), so a dataset that
-- predates it simply has neither. Every caller must read nil as "not
-- recorded", never as "this quest rewards nothing".

-- VMaNGOS's base RewXP for the quest. It is the value before the client's own
-- level scaling, so it is the quest's listed reward and not a prediction of
-- what this character would actually be granted.
function Database:GetQuestRewardXP(questId)
    local quest = self:GetQuest(questId)
    local xp = quest and quest.xp
    if type(xp) ~= "number" or xp <= 0 then
        return nil
    end
    return xp
end

-- quests[id].rep is FLAT -- { factionId, value, factionId, value, ... } -- not
-- a list of pairs. It is expanded here so no caller has to know the stride.
-- Returns { { faction = id, value = delta }, ... } in the recorded order, or
-- nil. A delta may be negative: quest 1 rewards +75 with one faction and -500
-- with another, so callers must not assume a gain.
function Database:GetQuestRewardReputation(questId)
    local quest = self:GetQuest(questId)
    local rep = quest and quest.rep
    if type(rep) ~= "table" then
        return nil
    end
    local list = {}
    local index = 1
    local count = table.getn(rep)
    while index < count do
        local faction = rep[index]
        local value = rep[index + 1]
        if type(faction) == "number" and type(value) == "number" and value ~= 0 then
            table.insert(list, { faction = faction, value = value })
        end
        index = index + 2
    end
    if table.getn(list) == 0 then
        return nil
    end
    return list
end

-- quests[id].skill is the VMaNGOS RequiredSkillId: a profession or secondary
-- skill line id (164 Blacksmithing, 185 Cooking, 129 First Aid, ...). 144
-- quests carry it; the data records no minimum skill rank.
function Database:GetQuestSkill(questId)
    local quest = self:GetQuest(questId)
    local skill = quest and quest.skill
    if type(skill) ~= "number" or skill <= 0 then
        return nil
    end
    return skill
end

-- Skill line id -> lowercased names the client may list it under: the
-- client-locale name and the enUS one, since the Skills pane is the only place
-- the player's skills can be read and it reports names, never ids. Returns an
-- empty table when neither table names the id.
function Database:GetSkillNames(skillId)
    local names = {}
    if not db or type(skillId) ~= "number" then
        return names
    end
    local localized = LocaleTable("professions")
    local english = db["professions_enUS"]
    if type(localized) == "table" and type(localized[skillId]) == "string" then
        table.insert(names, string.lower(localized[skillId]))
    end
    if type(english) == "table" and english ~= localized
        and type(english[skillId]) == "string" then
        table.insert(names, string.lower(english[skillId]))
    end
    return names
end

-- Faction id -> display name, or nil when nothing can name it.
--
-- Nothing in the bundled data or on this client maps a faction id to a name.
-- The client's whole Faction surface is indexed off the player's own
-- reputation pane -- GetFactionInfo(index) is a 1-based walk of the factions
-- THAT character has met and never reports an id -- so it cannot answer
-- "what is 529 called". An optional Database/factions.lua may supply the
-- names, per locale like every other text table; without it callers render
-- the amount on its own rather than inventing a label.
function Database:GetFactionName(factionId)
    if not db or type(factionId) ~= "number" then
        return nil
    end
    local names = LocaleTable("factions")
    if type(names) ~= "table" then
        names = db.factions
    end
    if type(names) ~= "table" then
        return nil
    end
    local name = names[factionId]
    if type(name) == "table" then
        name = name.T or name.N
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
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
--
-- One quest may answer differently from the account-wide setting: the quest
-- log's flag records a per-quest language (UQ.SetQuestLanguageOverride,
-- Core/Locale.lua) and it is consulted here rather than in any one surface, so
-- every surface that shows that quest agrees about which language it is in.
-- An override naming the CLIENT's own locale falls through the guard below to
-- the live text, which is exactly what "as the server wrote it" has to mean.
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
    local override = UQ.GetQuestLanguageOverride
        and UQ.GetQuestLanguageOverride(questId)
    if type(override) == "string" then
        translate = true
        language = override
    end
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
--
-- The mapped value is `true` for a kill objective and, for an item objective,
-- the drop rate `items[id].U` records for that creature -- a percentage, not a
-- fraction (`12.69` means 12.69%). Callers must test it for truth rather than
-- for equality with `true`, and must accept `true` where no rate is recorded.
-- One name can belong to several creature IDs with different loot tables (the
-- same "Defias Trapper" appears more than once), and the live tooltip only
-- ever gives a name, so the best of them is kept: reporting the worst of a
-- shared name would tell the player a mob is a poor source when the one in
-- front of them is not.
function Database:GetQuestObjectiveUnitLinks(questId)
    local relation = self:GetQuestObjectiveSources(questId)
    if type(relation) ~= "table" then
        return {}
    end

    local links = {}

    local function LinkUnit(unitId, objectiveName, dropRate)
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
        local value = true
        if type(dropRate) == "number" and dropRate > 0 then
            value = dropRate
        end
        local existing = objectives[objectiveKey]
        if type(existing) == "number" and type(value) == "number"
            and existing > value then
            return
        end
        if existing ~= nil and type(value) ~= "number" then
            return
        end
        objectives[objectiveKey] = value
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
                local unitId, dropRate
                for unitId, dropRate in pairs(item.U) do
                    LinkUnit(unitId, itemName, dropRate)
                end
            end
        end
    end

    return links
end

-- The object half of GetQuestObjectiveUnitLinks: for every object the
-- objective relation puts on the map, the normalized names of the live
-- objective lines that object can satisfy.
--
-- Keyed by object ID, not by name as the unit table above is. That one serves
-- the tooltip, which never has more than a name to go on; this one serves the
-- map, whose location rows already carry the source ID, so there is no reason
-- to route the answer through a name several objects share.
--
-- A direct obj.O source is named by itself: the client formats a gobject
-- objective with the object's own name. An object reached through obj.I is
-- named by the ITEM it holds instead -- the log says "Burning Key: 0/1", never
-- "Stone of West Binding" -- and that indirection is the reason a quest
-- sending the player to three containers for three different items could not
-- tell which of them was already emptied.
--
-- The value is `true` rather than a rate: an object either holds the quest
-- item or it does not, and the bundled per-object chance carries no meaning
-- the map would draw.
function Database:GetQuestObjectiveObjectLinks(questId)
    if type(questId) ~= "number" then
        return {}
    end
    local cached = questObjectiveObjectLinkCache[questId]
    if cached then
        return cached
    end

    local links = {}

    local function LinkObject(objectId, objectiveName)
        if type(objectId) ~= "number" then
            return
        end
        local objectiveKey = UQ.NameKey(objectiveName)
        if not objectiveKey then
            return
        end
        local names = links[objectId]
        if not names then
            names = {}
            links[objectId] = names
        end
        names[objectiveKey] = true
    end

    local relation = self:GetQuestObjectiveSources(questId)
    if type(relation) == "table" then
        if type(relation.O) == "table" then
            local _, objectId
            for _, objectId in pairs(relation.O) do
                LinkObject(objectId, self:GetObjectName(objectId))
            end
        end
        if type(relation.I) == "table" then
            local _, itemId
            for _, itemId in pairs(relation.I) do
                local item = self:GetItem(itemId)
                local itemName = self:GetItemName(itemId)
                if type(item) == "table" and type(item.O) == "table" then
                    local objectId
                    for objectId in pairs(item.O) do
                        LinkObject(objectId, itemName)
                    end
                end
            end
        end
    end

    questObjectiveObjectLinkCache[questId] = links
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

-- Every localized creature record that has at least one usable world
-- coordinate, sorted by name then ID. "Mob" is the player-facing name of this
-- finder; the data itself does not distinguish hostile creatures from friendly
-- NPCs, so this deliberately exposes the complete unit table instead of
-- inventing a hostility test the database cannot support.
function Database:GetMobSearchIndex()
    if self.mobSearchIndex then
        return self.mobSearchIndex
    end

    local rows = {}
    self.mobSearchIndex = rows
    local names = LocaleTable("units")
    local units = db and db.units
    if type(names) ~= "table" or type(units) ~= "table" then
        return rows
    end

    local unitId, name
    for unitId, name in pairs(names) do
        local record = units[unitId]
        if type(unitId) == "number" and type(name) == "string" and name ~= ""
            and type(record) == "table" and type(record.coords) == "table"
            and table.getn(record.coords) > 0 then
            table.insert(rows, {
                unitId = unitId,
                name = name,
                searchName = string.lower(name),
                level = record.lvl,
            })
        end
    end

    table.sort(rows, function(left, right)
        if left.searchName ~= right.searchName then
            return left.searchName < right.searchName
        end
        return left.unitId < right.unitId
    end)
    return rows
end

-- Case-insensitive for ASCII names and exact-byte for scripts Lua's legacy
-- string.lower does not fold. An empty query intentionally returns the whole
-- index so the fixed settings list can page through the database before a
-- filter is entered.
-- Every zone a creature has recorded spawns in, the one with the most spawns
-- first. Each row is { areaId, name, count }.
--
-- Counted rather than deduplicated, because "which zone is this creature in?"
-- has no single answer for a creature recorded in several: a Defias thug with
-- forty spawns in Westfall and one in Elwynn is a Westfall creature, and the
-- caller wants to be told that rather than whichever areaId the coords happen
-- to list first.
--
-- A spawn whose area has no name in the current locale's zone table is skipped
-- rather than shown as its number: an area ID is not something to put in front
-- of a player, and the alternative -- inventing a name -- is worse.
function Database:GetUnitZones(unitId)
    local zones = {}
    local record = self:GetUnit(unitId)
    if type(record) ~= "table" or type(record.coords) ~= "table" then
        return zones
    end

    local byArea = {}
    local coords = record.coords
    local index = 1
    local total = table.getn(coords)
    while index <= total do
        local coordinate = coords[index]
        local areaId = type(coordinate) == "table" and coordinate[3]
        if type(areaId) == "number" then
            local zone = byArea[areaId]
            if zone then
                zone.count = zone.count + 1
            else
                local name = self:GetZoneName(areaId)
                if type(name) == "string" and name ~= "" then
                    zone = { areaId = areaId, name = name, count = 1 }
                    byArea[areaId] = zone
                    table.insert(zones, zone)
                end
            end
        end
        index = index + 1
    end

    -- The area ID breaks an exact tie, so the answer does not depend on the
    -- order the coordinate list happened to be walked in.
    table.sort(zones, function(left, right)
        if left.count ~= right.count then
            return left.count > right.count
        end
        return left.areaId < right.areaId
    end)
    return zones
end

-- One search row by unit ID, for a caller that already knows which creature it
-- wants and not what the player typed. The options page needs it to keep the
-- tracked creature pinned at the top of the list even while the search below
-- it is showing something else entirely.
--
-- Indexed off the same rows the search walks, so a creature with no recorded
-- coordinates is absent from both: this returns nil rather than a record the
-- map could not draw.
function Database:GetMobSearchRecord(unitId)
    if type(unitId) ~= "number" then
        return nil
    end
    if not self.mobSearchById then
        local byId = {}
        local rows = self:GetMobSearchIndex()
        local index = 1
        local total = table.getn(rows)
        while index <= total do
            byId[rows[index].unitId] = rows[index]
            index = index + 1
        end
        self.mobSearchById = byId
    end
    return self.mobSearchById[unitId]
end

function Database:SearchMobsByName(query)
    query = type(query) == "string" and query or ""
    query = string.gsub(query, "^%s+", "")
    query = string.gsub(query, "%s+$", "")
    local needle = string.lower(query)
    local source = self:GetMobSearchIndex()
    if needle == "" then
        return source
    end

    local matches = {}
    local index = 1
    local total = table.getn(source)
    while index <= total do
        local row = source[index]
        if string.find(row.searchName, needle, 1, true) then
            table.insert(matches, row)
        end
        index = index + 1
    end
    return matches
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

-- Returns the shortest and longest positive respawn durations attached to
-- records bearing this exact localized tooltip name. Same-named creature or
-- object records can legitimately disagree, so callers present a range rather
-- than guessing which numeric ID the name-only tooltip belongs to.
-- The same shortest/longest pair for one creature ID, read straight off its
-- spawns' fourth coordinate field (seconds). A map pin knows its creature's
-- ID, so it does not need the name index above or to wait for it. With an
-- area, only that zone's spawns count, unless none of them carries a value.
function Database:GetUnitRespawn(unitId, areaId)
    local unit = self:GetUnit(unitId)
    local coords = type(unit) == "table" and unit.coords or nil
    if type(coords) ~= "table" then
        return nil, nil
    end
    local minimum, maximum, zoneMinimum, zoneMaximum
    local index = 1
    local total = table.getn(coords)
    while index <= total do
        local coordinate = coords[index]
        local seconds = type(coordinate) == "table" and coordinate[4] or nil
        if type(seconds) == "number" and seconds > 0 then
            if not minimum or seconds < minimum then minimum = seconds end
            if not maximum or seconds > maximum then maximum = seconds end
            if areaId and coordinate[3] == areaId then
                if not zoneMinimum or seconds < zoneMinimum then zoneMinimum = seconds end
                if not zoneMaximum or seconds > zoneMaximum then zoneMaximum = seconds end
            end
        end
        index = index + 1
    end
    if zoneMinimum then
        return zoneMinimum, zoneMaximum
    end
    return minimum, maximum
end

function Database:GetEntityRespawn(unitKey)
    if type(unitKey) ~= "string" or unitKey == "" then
        return nil, nil, self.respawnIndexReady, self.respawnIndexRevision
    end
    local entry = self.respawnIndex[unitKey]
    if not entry then
        return nil, nil, self.respawnIndexReady, self.respawnIndexRevision
    end
    return entry.minimum, entry.maximum,
        self.respawnIndexReady, self.respawnIndexRevision
end

function Database:GetItem(itemId)
    if not db or type(db.items) ~= "table" then
        return nil
    end
    return db.items[itemId]
end

-- Everything a creature can drop, for the finder's loot tooltip.
--
-- The bundled tables only index item -> creature (`items[id].U`, the drop
-- rate in percent), so this walks every item once per creature asked about
-- and caches the answer. Only a click asks, and only for one creature at a
-- time, so a full inverse index over ~200k links would be memory spent on
-- creatures nobody opens.
--
-- `items[id].R` names reference loot tables (`refloot[ref].U` lists the
-- creatures sharing one). 97% of those links carry a chance of 0: the item is
-- one of an equal-chance group whose own roll was not packaged, so no real
-- percentage exists for it. A reference link with a recorded chance is kept as
-- a drop; the rest are only counted, never given an invented rate.
--
-- Returns a list of { itemId, chance } sorted by chance, highest first,
-- plus the count of unrated shared-table items.
function Database:GetUnitLoot(unitId)
    if type(unitId) ~= "number" or not db or type(db.items) ~= "table" then
        return {}, 0
    end
    self.unitLootCache = self.unitLootCache or {}
    local cached = self.unitLootCache[unitId]
    if cached then
        return cached.drops, cached.shared
    end
    local refloot = db.refloot
    local drops = {}
    local shared = 0
    local itemId, item
    for itemId, item in pairs(db.items) do
        if type(item) == "table" then
            local chance = nil
            if type(item.U) == "table" and type(item.U[unitId]) == "number" then
                chance = item.U[unitId]
            end
            if not chance and type(item.R) == "table" and type(refloot) == "table" then
                local refId, refChance
                local unrated = false
                for refId, refChance in pairs(item.R) do
                    local ref = refloot[refId]
                    if type(ref) == "table" and type(ref.U) == "table" and ref.U[unitId] then
                        if type(refChance) == "number" and refChance > 0 then
                            if not chance or refChance > chance then
                                chance = refChance
                            end
                        else
                            unrated = true
                        end
                    end
                end
                if not chance and unrated then
                    shared = shared + 1
                end
            end
            if chance and chance > 0 then
                table.insert(drops, { itemId = itemId, chance = chance })
            end
        end
    end
    table.sort(drops, function(a, b)
        if a.chance ~= b.chance then
            return a.chance > b.chance
        end
        return a.itemId < b.itemId
    end)
    self.unitLootCache[unitId] = { drops = drops, shared = shared }
    return drops, shared
end

function Database:GetItemName(itemId)
    local names = LocaleTable("items")
    if type(names) ~= "table" then
        return nil
    end
    return names[itemId]
end

function Database:GetItemNameForLanguage(itemId, language)
    local names = ExactLocaleTable("items", language)
    if type(names) ~= "table" then
        return nil
    end
    local name = names[itemId]
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

-- Translate a live client-locale item name only when every item ID carrying
-- that exact native name agrees on the requested translation. Duplicate names
-- are valid in the source data; disagreement therefore fails closed instead
-- of putting another item's name on a reward button.
function Database:GetItemDisplayNameForLanguage(nativeName, language)
    if type(nativeName) ~= "string" or nativeName == ""
        or not self.itemNameIndexReady or type(self.itemNameIndex) ~= "table" then
        return nil
    end
    local ids = self.itemNameIndex[nativeName]
    if type(ids) == "number" then
        local translated = self:GetItemNameForLanguage(ids, language)
        if translated and UQ.PrepareTranslatedGameText then
            translated = UQ.PrepareTranslatedGameText(translated, language)
        end
        return translated
    end
    if type(ids) ~= "table" then
        return nil
    end
    local translated = nil
    local index = 1
    local total = table.getn(ids)
    while index <= total do
        local candidate = self:GetItemNameForLanguage(ids[index], language)
        if candidate then
            if translated and translated ~= candidate then
                return nil
            end
            translated = candidate
        end
        index = index + 1
    end
    if translated and UQ.PrepareTranslatedGameText then
        translated = UQ.PrepareTranslatedGameText(translated, language)
    end
    return translated
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

-- Instance interiors --------------------------------------------------------
--
-- Two questions the tracker's current-zone filter has to answer once the
-- player steps through a dungeon portal, and neither can be answered by a
-- coordinate: THE BUNDLED DATA RECORDS NO POSITION INSIDE AN INSTANCE AT ALL.
-- Every coordinate in units.lua and objects.lua sits in one of the 50 outdoor
-- areas the client draws a map for; area 1581 (The Deadmines), 718 (Wailing
-- Caverns) and every other instance interior hold none, which is precisely why
-- Database/instance_only_units.lua exists. So "does this quest have work here"
-- becomes a membership question over the instance map ID, not a map question.
--
--   1. which instance map is the player standing in, given the area their
--      zone name resolved to -- GetInstanceMapForArea below;
--   2. which instance maps does this quest have recorded work on --
--      GetQuestInstanceMaps below.

-- areaId -> instance map ID, for the areas Database/instances.lua names.
--
-- The join is by NAME, and deliberately by the ENGLISH name on both sides:
-- instances.lua carries the VMaNGOS instance name, which is English whatever
-- the client's locale is, and zones_enUS carries the English area name from
-- the same source. The caller has already resolved the player's localized zone
-- name to an area ID through the localized zone table, so routing the
-- comparison through the area ID keeps the whole thing locale-proof.
--
-- Several areas may carry an instance's name -- Shadowfang Keep is both the
-- interior (209) and the Silverpine exterior (236) -- so the index is built in
-- the areaId -> mapId direction, where that is not an ambiguity. Only one of
-- the 26 bundled instances files no area at all under its own name (map 531,
-- Temple of Ahn'Qiraj), and a missing entry simply leaves the caller without
-- the instance half, never with a wrong one.
--
-- Built on the first ask and kept: both tables are static for the session.
function Database:GetInstanceMapForArea(areaId)
    if not self.instanceAreaIndex then
        local index = {}
        self.instanceAreaIndex = index
        local instances = db and db.instances
        local names = db and db.zones_enUS
        if type(instances) == "table" and type(names) == "table" then
            -- One pass over the English area names, so the walk is
            -- names + instances rather than names x instances.
            local byName = {}
            local zoneId, zoneName
            for zoneId, zoneName in pairs(names) do
                local key = UQ.NameKey(zoneName)
                if key then
                    local bucket = byName[key]
                    if not bucket then
                        bucket = {}
                        byName[key] = bucket
                    end
                    table.insert(bucket, zoneId)
                end
            end
            local mapId, record
            for mapId, record in pairs(instances) do
                local instanceName = nil
                if type(record) == "table" then
                    instanceName = record.name
                end
                local key = nil
                if type(instanceName) == "string" then
                    key = UQ.NameKey(instanceName)
                end
                local bucket = nil
                if key then
                    bucket = byName[key]
                end
                if bucket then
                    local bucketIndex = 1
                    local bucketTotal = table.getn(bucket)
                    while bucketIndex <= bucketTotal do
                        index[bucket[bucketIndex]] = mapId
                        bucketIndex = bucketIndex + 1
                    end
                end
            end
        end
    end
    if type(areaId) ~= "number" then
        return nil
    end
    return self.instanceAreaIndex[areaId]
end

-- Which instance maps a quest has recorded work on, as two sets keyed by map
-- ID: `objective` for the creatures its objective relation names (directly, or
-- as the droppers of an objective item), and `turnIn` for the creature it is
-- handed back to. The split mirrors what Map/QuestZonePresence.lua already
-- asks of the map -- a completed quest shows its ender and nothing else -- so
-- one caller can pick the same half in the same situation.
--
-- Objects are absent on purpose. An in-instance container has no coordinate
-- and no provenance table of its own, so there is nothing to test it against;
-- a quest reaching an instance only through an object stays undecided here
-- rather than being answered wrongly.
--
-- Static, so it is cached for the session. Both sets may be empty, which is
-- the ordinary answer for the overwhelming majority of quests.
function Database:GetQuestInstanceMaps(questId)
    if type(questId) ~= "number" then
        return nil
    end
    local cached = questInstanceMapCache[questId]
    if cached then
        return cached
    end
    local record = self:GetQuest(questId)
    if not record then
        return nil
    end

    local maps = { objective = {}, turnIn = {} }

    local function AddUnit(set, unitId)
        if type(unitId) ~= "number" or not db
            or type(db.instance_only_units) ~= "table" then
            return
        end
        local sourceMaps = db.instance_only_units[unitId]
        if type(sourceMaps) ~= "table" then
            return
        end
        local mapId, present
        for mapId, present in pairs(sourceMaps) do
            if present == true and type(mapId) == "number" then
                set[mapId] = true
            end
        end
    end

    local function AddRelation(set, relation)
        if type(relation) ~= "table" then
            return
        end
        if type(relation.U) == "table" then
            local _, unitId
            for _, unitId in pairs(relation.U) do
                AddUnit(set, unitId)
            end
        end
        if type(relation.I) == "table" then
            local _, itemId
            for _, itemId in pairs(relation.I) do
                local item = self:GetItem(itemId)
                if type(item) == "table" and type(item.U) == "table" then
                    local unitId, _
                    for unitId, _ in pairs(item.U) do
                        AddUnit(set, unitId)
                    end
                end
            end
        end
    end

    AddRelation(maps.objective, record["obj"])
    AddRelation(maps.turnIn, record["end"])

    if questInstanceMapCacheCount >= MAX_QUEST_INSTANCE_MAP_CACHE then
        questInstanceMapCache = {}
        questInstanceMapCacheCount = 0
    end
    questInstanceMapCache[questId] = maps
    questInstanceMapCacheCount = questInstanceMapCacheCount + 1
    return maps
end

-- True when any recorded work of the quest -- an objective creature or the
-- turn-in -- is inside a dungeon or raid. Bundled data only: GetQuestLogTitle's
-- questTag was nil in every captured sample, so the client is not asked.
function Database:IsDungeonQuest(questId)
    local maps = self:GetQuestInstanceMaps(questId)
    if not maps then
        return false
    end
    return next(maps.objective) ~= nil or next(maps.turnIn) ~= nil
end

-- The one level label every addon-owned presentation shows: "24", or "24+"
-- for a dungeon quest. An unmatched or ambiguous quest has no questId and so
-- never gains the "+" -- a hypothesis must not be dressed up as a fact.
function UQ.FormatQuestLevel(level, questOrId)
    local text = tostring(level)
    local questId = type(questOrId) == "table" and questOrId.questId or questOrId
    local database = UQ:GetModule("Database")
    if type(questId) == "number" and database
        and type(database.IsDungeonQuest) == "function"
        and database:IsDungeonQuest(questId) then
        text = text .. "+"
    end
    return text
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

-- Expands selected unit IDs into direct coordinates for one map area. The
-- caller owns pin budgets and presentation; this adapter only reads the
-- bundled data and decorates the normalized entity-location rows.
function Database:GetTrackedMobLocations(areaId, unitIds, limit)
    local locations = {}
    if type(areaId) ~= "number" or type(unitIds) ~= "table" then
        return locations
    end
    if type(limit) ~= "number" or limit < 1 then
        limit = nil
    end

    local index = 1
    local total = table.getn(unitIds)
    while index <= total and (not limit or table.getn(locations) < limit) do
        local unitId = unitIds[index]
        local remaining = nil
        if limit then
            remaining = limit - table.getn(locations)
        end
        local found = self:GetEntityLocations("unit", unitId, areaId, remaining)
        local foundIndex = 1
        local foundTotal = table.getn(found)
        local name = self:GetUnitName(unitId)
        while foundIndex <= foundTotal do
            local location = found[foundIndex]
            location.category = "tracked"
            location.name = type(name) == "string" and name or tostring(unitId)
            table.insert(locations, location)
            foundIndex = foundIndex + 1
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

-- UnitClassification tokens from the client's documented Unit API. Rank 1
-- is deliberately absent: ordinary elites appear on the finder map but never
-- raise an alert, so they do not belong in the alert's kill history either.
local ALERT_CLASSIFICATION_RANK = {
    rareelite = RANK_RARE_ELITE,
    worldboss = RANK_BOSS,
    rare = RANK_RARE,
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
        self.rankedUnitNameIndex = {}
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
                    if self:IsAlertWorthy(unitId) then
                        local key = UQ.NameKey(self:GetUnitName(unitId))
                        if key then
                            local named = self.rankedUnitNameIndex[key]
                            if not named then
                                named = {}
                                self.rankedUnitNameIndex[key] = named
                            end
                            table.insert(named, { unitId = unitId, rank = rank })
                        end
                    end
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

-- Resolves a live target to the one alert-worthy database creature carrying
-- both its localized name and its documented classification. The client has
-- no creature ID or GUID API, so an ambiguous shared name is refused rather
-- than filing a kill under an arbitrary record.
function Database:FindAlertWorthyUnitByName(name, classification)
    if not self.rankIndexReady or type(self.rankedUnitNameIndex) ~= "table" then
        return nil
    end
    local expectedRank = ALERT_CLASSIFICATION_RANK[classification]
    local key = UQ.NameKey(name)
    local bucket = key and self.rankedUnitNameIndex[key] or nil
    if not expectedRank or type(bucket) ~= "table" then
        return nil
    end
    local match = nil
    local index = 1
    local total = table.getn(bucket)
    while index <= total do
        local entry = bucket[index]
        if entry.rank == expectedRank then
            if match and match.unitId ~= entry.unitId then
                return nil
            end
            match = entry
        end
        index = index + 1
    end
    return match
end

-- Title index ---------------------------------------------------------------
-- Quest titles are not unique in the source data, so the index maps a
-- normalized title to a list of candidate quest IDs. Disambiguation is the
-- matcher's job.

function Database:IndexItemNameChunk()
    if not self.available or self.itemNameIndexReady then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("database.itemnames")
        end
        return
    end

    if not self.itemNameIndex then
        self.itemNameIndex = {}
    end

    local names = LocaleTable("items")
    if type(names) ~= "table" then
        self.itemNameIndexReady = true
        return
    end

    local processed = 0
    while processed < INDEX_CHUNK do
        local itemId, name = next(names, itemNameIndexCursor)
        if itemId == nil then
            self.itemNameIndexReady = true
            UQ:Debug("item name index complete: "
                .. self.itemNameIndexedCount .. " items")
            local driver = UQ:GetModule("Driver")
            if driver then
                driver:Unschedule("database.itemnames")
            end
            return
        end
        itemNameIndexCursor = itemId

        if type(name) == "string" and name ~= "" then
            local existing = self.itemNameIndex[name]
            if not existing then
                self.itemNameIndex[name] = itemId
            elseif type(existing) == "number" then
                self.itemNameIndex[name] = { existing, itemId }
            else
                table.insert(existing, itemId)
            end
            self.itemNameIndexedCount = self.itemNameIndexedCount + 1
        end

        processed = processed + 1
    end
end

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

-- Respawn-name index -------------------------------------------------------

-- A positive respawn value on a world-object spawn does not mean the object
-- can meaningfully respawn for the player. The source database gives the same
-- field to permanent scenery such as city direction signs. Keep only objects
-- that another world-data relation establishes as actionable: quest
-- starters/finishers/objectives, loot containers, or item-use targets.
local function MarkRespawnRelationObjects(relation)
    local objects = type(relation) == "table" and relation.O or nil
    if type(objects) ~= "table" then
        return
    end
    local _, objectId
    for _, objectId in pairs(objects) do
        if type(objectId) == "number" then
            respawnObjectIds[objectId] = true
        end
    end
end

local function MarkRespawnRelationItems(relation)
    if type(relation) ~= "table" then
        return
    end
    local _, itemId
    for _, itemId in pairs(relation) do
        if type(itemId) == "number" then
            respawnItemIds[itemId] = true
        end
    end
end

local function IndexRespawnQuestObjects(record)
    if type(record) ~= "table" then
        return
    end
    MarkRespawnRelationObjects(record["start"])
    MarkRespawnRelationObjects(record["end"])
    MarkRespawnRelationObjects(record.obj)

    local objective = record.obj
    if type(objective) ~= "table" then
        return
    end
    MarkRespawnRelationItems(objective.I)
    MarkRespawnRelationItems(objective.IR)
end

local function IndexRespawnLootObjects(record)
    local objects = type(record) == "table" and record.O or nil
    if type(objects) ~= "table" then
        return
    end
    local objectId
    for objectId in pairs(objects) do
        if type(objectId) == "number" then
            respawnObjectIds[objectId] = true
        end
    end
end

local function IndexRespawnItemUseObjects(targets)
    if type(targets) ~= "table" then
        return
    end
    local targetId
    for targetId in pairs(targets) do
        if type(targetId) == "number" and targetId < 0 then
            respawnObjectIds[-targetId] = true
        end
    end
end

local RESPAWN_NODE_META_KEYS = { "chests", "fish", "herbs", "mines" }

local function AdvanceRespawnIndexSource(module)
    if respawnIndexSource == "unit" then
        respawnIndexSource = "quest"
    elseif respawnIndexSource == "quest" then
        respawnIndexSource = "item"
    elseif respawnIndexSource == "item" then
        respawnIndexSource = "itemUse"
    elseif respawnIndexSource == "itemUse" then
        respawnIndexSource = "node"
    elseif respawnIndexSource == "node" then
        respawnNodeCategoryIndex = respawnNodeCategoryIndex + 1
        if respawnNodeCategoryIndex > table.getn(RESPAWN_NODE_META_KEYS) then
            respawnIndexSource = "object"
        end
    else
        module.respawnIndexReady = true
    end
    respawnIndexCursor = nil
end

local function AddRespawnDurations(module, name, entity)
    local key = UQ.NameKey(name)
    local coords = type(entity) == "table" and entity.coords or nil
    if not key or type(coords) ~= "table" then
        return
    end

    local minimum = nil
    local maximum = nil
    local coordinateIndex = 1
    local coordinateTotal = table.getn(coords)
    while coordinateIndex <= coordinateTotal do
        local coordinate = coords[coordinateIndex]
        local seconds = type(coordinate) == "table" and coordinate[4] or nil
        if type(seconds) == "number" and seconds > 0 then
            if not minimum or seconds < minimum then
                minimum = seconds
            end
            if not maximum or seconds > maximum then
                maximum = seconds
            end
        end
        coordinateIndex = coordinateIndex + 1
    end
    if not minimum then
        return
    end

    local entry = module.respawnIndex[key]
    if not entry then
        entry = { minimum = minimum, maximum = maximum }
        module.respawnIndex[key] = entry
        module.respawnIndexedCount = module.respawnIndexedCount + 1
    else
        if minimum < entry.minimum then
            entry.minimum = minimum
        end
        if maximum > entry.maximum then
            entry.maximum = maximum
        end
    end
    module.respawnIndexRevision = module.respawnIndexRevision + 1
end

function Database:IndexRespawnChunk()
    if not self.available or self.respawnIndexReady then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("database.respawnindex")
        end
        return
    end

    local processed = 0
    while processed < INDEX_CHUNK do
        local source = nil
        if respawnIndexSource == "unit" then
            source = db.units
        elseif respawnIndexSource == "quest" then
            source = db.quests
        elseif respawnIndexSource == "item" then
            source = respawnItemIds
        elseif respawnIndexSource == "itemUse" then
            source = db["quests-itemreq"]
        elseif respawnIndexSource == "node" then
            local meta = db.meta
            if type(meta) == "table" then
                source = meta[RESPAWN_NODE_META_KEYS[respawnNodeCategoryIndex]]
            end
        else
            source = respawnObjectIds
        end

        if type(source) ~= "table" then
            AdvanceRespawnIndexSource(self)
        else
            local entityId, entity = next(source, respawnIndexCursor)
            if entityId == nil then
                AdvanceRespawnIndexSource(self)
            else
                respawnIndexCursor = entityId
                if respawnIndexSource == "unit" then
                    local names = LocaleTable("units")
                    AddRespawnDurations(self,
                        type(names) == "table" and names[entityId] or nil, entity)
                elseif respawnIndexSource == "quest" then
                    IndexRespawnQuestObjects(entity)
                elseif respawnIndexSource == "item" then
                    IndexRespawnLootObjects(db.items and db.items[entityId])
                elseif respawnIndexSource == "itemUse" then
                    IndexRespawnItemUseObjects(entity)
                elseif respawnIndexSource == "node" then
                    if type(entityId) == "number" and entityId < 0 then
                        respawnObjectIds[-entityId] = true
                    end
                else
                    local names = LocaleTable("objects")
                    AddRespawnDurations(self,
                        type(names) == "table" and names[entityId] or nil,
                        db.objects and db.objects[entityId])
                end
                processed = processed + 1
            end
        end

        if self.respawnIndexReady then
            UQ:Debug("respawn index complete: " .. self.respawnIndexedCount .. " names")
            local driver = UQ:GetModule("Driver")
            if driver then
                driver:Unschedule("database.respawnindex")
            end
            return
        end
    end
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
