--[[
UnrealQuest / Data/ObjectiveMatch.lua

Answers one question, for anything that has a creature's name and wants to know
what the quest log wants with it: "does this creature satisfy an objective of a
quest I am on, and how far along is it?"

The answer is built the way pfQuest builds it
(Interface/AddOns/pfQuest/map.lua, pfMap:ShowTooltip), because pfQuest's is
confirmed working on this install:

  * The creature name and both counters are parsed out of the **live quest log
    line itself**, using the client's own QUEST_MONSTERS_KILLED /
    QUEST_OBJECTS_FOUND / QUEST_ITEMS_NEEDED format strings turned into
    patterns. "Kobold Vermin slain: 4/10" already names the creature, so a kill
    objective is answered with no quest ID, no title match against the bundled
    world data, and no world-data record at all -- which also means a quest
    whose title this server changed still works.
  * The bundled database is consulted only where the log line genuinely cannot
    answer: an item objective ("Large Candle: 3/8") names the item, not the
    kobolds that drop it, so the item -> creature link has to come from the
    world data. That path needs a resolved quest ID and returns nothing
    without one.

Tooltip/EntityTooltip.lua is the consumer: it turns a result into tooltip
lines. The matching lives here rather than in it so that a second consumer --
anything that wants to know what a creature is for -- cannot disagree with the
tooltip about the same creature.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local ObjectiveMatch = UQ:NewModule("ObjectiveMatch")

-- Distinct creature names remembered before the whole cache is thrown away.
-- The cache is flushed on every quest model change anyway; this only bounds a
-- long session spent hovering scenery in a busy city.
local MAX_CACHE_ENTRIES = 200

-- Objective line parsing ----------------------------------------------------

-- Turns one of the client's format strings into a pattern with a capture per
-- placeholder. This is pfUI.api.SanitizePattern (UnrealPfUI/api/api.lua:267),
-- which is what pfQuest itself calls before matching an objective line; it is
-- reimplemented here rather than depended on because neither pfUI nor pfQuest
-- is a dependency of this addon.
--
-- "%s slain: %d/%d"  ->  "(.+) slain: (%d+)/(%d+)"
local function SanitizePattern(text)
    -- escape the pattern magic characters the localized string may contain
    local pattern = string.gsub(text, "([%+%-%*%(%)%?%[%]%^])", "%%%1")
    -- drop positional capture indexes ("%1$s"), which locales use to reorder
    pattern = string.gsub(pattern, "%d%$", "")
    -- turn every remaining placeholder into a capture. Only "%" is special in
    -- a replacement string, so the parentheses go in literally; pfUI escapes
    -- them, which older Lua tolerates and newer Lua rejects.
    pattern = string.gsub(pattern, "(%%%a)", "(%1+)")
    -- a string placeholder matches anything, not just letters
    pattern = string.gsub(pattern, "%%s%+", ".+")
    -- where a string capture runs straight into a number one, let the number win
    pattern = string.gsub(pattern, "%(.%+%)%(%%d%+%)", "(.-)(%%d+)")
    return pattern
end

-- GetQuestLogLeaderBoard's documented objective types on this client are
-- "monster", "item" and "gobject" (not "object"), and the client's own
-- reference names the global string each one is formatted with.
local PATTERN_FOR_TYPE = {
    monster = "QUEST_MONSTERS_KILLED",
    item = "QUEST_OBJECTS_FOUND",
    gobject = "QUEST_OBJECTS_FOUND",
}

-- Tried in this order when the objective carries no usable type. Kill lines
-- first: "Kobold Vermin slain: 4/10" also satisfies the plainer
-- QUEST_OBJECTS_FOUND shape, but with " slain" glued onto the creature name.
local PATTERN_ORDER = {
    "QUEST_MONSTERS_KILLED",
    "QUEST_OBJECTS_FOUND",
    "QUEST_ITEMS_NEEDED",
}

-- Which kind of thing a line parsed by each format string names. A kill line
-- names the creature itself, so it answers the question outright; every other
-- line names an item or an object, which still has to be linked to a creature.
local PATTERN_KIND = {
    QUEST_MONSTERS_KILLED = "monster",
    QUEST_OBJECTS_FOUND = "item",
    QUEST_ITEMS_NEEDED = "item",
}

local patternCache = {}

local function GetPattern(globalName)
    local cached = patternCache[globalName]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end
    local text = Client.GetGlobalString(globalName)
    if not text then
        patternCache[globalName] = false
        return nil
    end
    local pattern = SanitizePattern(text)
    patternCache[globalName] = pattern
    return pattern
end

local function MatchPattern(text, globalName)
    local pattern = GetPattern(globalName)
    if not pattern then
        return nil
    end
    local _, _, name, have, need = string.find(text, pattern)
    if type(name) ~= "string" or name == "" or not have or not need then
        return nil
    end
    return name, tonumber(have), tonumber(need)
end

-- Returns the objective's own name, its two counters, and whether that name is
-- a creature or a thing to collect. Returns nil when the line carries none of
-- it (an "explore the mine" objective, for instance).
function ObjectiveMatch:ParseLine(text, objectiveType)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    local preferred = objectiveType and PATTERN_FOR_TYPE[objectiveType]
    if preferred then
        local name, have, need = MatchPattern(text, preferred)
        if name then
            return name, have, need, PATTERN_KIND[preferred]
        end
    end

    local index = 1
    local total = table.getn(PATTERN_ORDER)
    while index <= total do
        local globalName = PATTERN_ORDER[index]
        if globalName ~= preferred then
            local name, have, need = MatchPattern(text, globalName)
            if name then
                return name, have, need, PATTERN_KIND[globalName]
            end
        end
        index = index + 1
    end

    return nil
end

-- Red at nothing done, yellow at half, green at complete. pfMap.tooltip:GetColor.
function ObjectiveMatch:ProgressColor(have, need)
    local maximum = need
    if type(maximum) ~= "number" or maximum <= 0 then
        maximum = 1
    end
    local current = have
    if type(current) ~= "number" then
        current = maximum
    end

    local percent = current / maximum
    if percent < 0 then
        percent = 0
    elseif percent > 1 then
        percent = 1
    end

    local r1, g1, b1, r2, g2, b2
    if percent <= 0.5 then
        percent = percent * 2
        r1, g1, b1 = 1, 0, 0
        r2, g2, b2 = 1, 1, 0
    else
        percent = percent * 2 - 1
        r1, g1, b1 = 1, 1, 0
        r2, g2, b2 = 0, 1, 0
    end

    return r1 + (r2 - r1) * percent,
           g1 + (g2 - g1) * percent,
           b1 + (b2 - b1) * percent
end

-- World data links ----------------------------------------------------------

-- Immutable per quest ID: the bundled data does not change under the addon, so
-- a resolved link table is cached forever rather than folded into a whole-log
-- index that can go stale. An earlier implementation kept exactly such an
-- index, built it once on the first poll after login -- before the database
-- title index had finished building, so before any quest had an ID -- and had
-- no way to learn it was wrong. See docs/CLIENT-COMPATIBILITY.md item 9.
ObjectiveMatch.linkCache = {}

function ObjectiveMatch:GetQuestLinks(questId)
    if type(questId) ~= "number" then
        return nil
    end
    local cached = self.linkCache[questId]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end
    local database = UQ:GetModule("Database")
    if not database then
        return nil
    end
    local links = database:GetQuestObjectiveUnitLinks(questId)
    if type(links) ~= "table" then
        self.linkCache[questId] = false
        return nil
    end
    self.linkCache[questId] = links
    return links
end

-- Returns whether the objective line names something this creature supplies,
-- and the drop rate the world data records for it when there is one (a
-- percentage; see Database:GetQuestObjectiveUnitLinks). Several keys can match
-- one line by substring -- an "Iron Ore" objective also contains "Ore" -- so
-- the longest match wins, which is the one that actually named the item and
-- therefore carries its rate.
local function ObjectiveMatchesLinks(objectiveText, objectiveKeys)
    local textKey = UQ.NameKey(objectiveText)
    if not textKey then
        return false
    end
    local bestLength = 0
    local bestValue = nil
    local objectiveKey, value
    for objectiveKey, value in pairs(objectiveKeys) do
        if string.find(textKey, objectiveKey, 1, true) then
            local length = string.len(objectiveKey)
            if length > bestLength then
                bestLength = length
                bestValue = value
            end
        end
    end
    if bestLength == 0 then
        return false
    end
    if type(bestValue) == "number" then
        return true, bestValue
    end
    return true
end

-- Matching ------------------------------------------------------------------

-- Bumped on every quest model notification, which includes a counter moving:
-- QuestState only reports QUEST_OBJECTIVES_CHANGED when an objective's text or
-- finished flag actually differs. That is what makes caching a parsed
-- have/need safe -- a change to either invalidates the whole cache.
ObjectiveMatch.questStamp = 0
ObjectiveMatch.cache = {}
ObjectiveMatch.cacheStamp = nil
ObjectiveMatch.cacheCount = 0

-- Walks the live quest log for a creature. Returns nil when it satisfies
-- nothing, or a list of
--   { quest, objectiveIndex, name, have, need, finished, fromDatabase,
--     dropRate }
-- plus the counts of matches found by each of the two paths. `dropRate` is
-- present only on a world-data item match that has a recorded rate, and is a
-- percentage rather than a fraction.
function ObjectiveMatch:Resolve(unitKey)
    local state = UQ:GetModule("QuestState")
    if not state or not unitKey then
        return nil
    end

    local results = {}
    local direct = 0
    local viaDatabase = 0

    local quests = state:GetOrderedQuests()
    local questIndex = 1
    local questTotal = table.getn(quests)
    while questIndex <= questTotal do
        local quest = quests[questIndex]
        if quest and quest.isComplete ~= 1 then
            local links = self:GetQuestLinks(quest.questId)
            local objectiveKeys = links and links[unitKey]
            local objectives = quest.objectives or {}

            local objectiveIndex = 1
            local objectiveTotal = table.getn(objectives)
            while objectiveIndex <= objectiveTotal do
                local objective = objectives[objectiveIndex]
                if objective then
                    local name, have, need, kind = self:ParseLine(
                        objective.text, objective.objectiveType)
                    local matched = false
                    local fromDatabase = false
                    local dropRate = nil

                    -- Resolved before the chain below rather than inside it,
                    -- so that a creature the world data links to this quest
                    -- but not to THIS line still falls through to the
                    -- unparsed-line fallback the way it always did.
                    local linkMatched, linkRate
                    if objectiveKeys then
                        linkMatched, linkRate = ObjectiveMatchesLinks(
                            objective.text, objectiveKeys)
                    end

                    if name and UQ.NameKey(name) == unitKey then
                        -- The kill path: the log line names this very creature.
                        matched = true
                    elseif name and kind == "monster" then
                        -- Also a kill line, but it names a different creature.
                        -- It is deliberately NOT handed to the world-data path
                        -- below: the objective sources of a quest like "Night
                        -- Web's Hollow" include both "Night Web Spider" and
                        -- "Young Night Web Spider", and a substring test would
                        -- report the young spider's objective for the adult
                        -- one. The line already named its creature, so that
                        -- answer is final.
                    elseif linkMatched then
                        -- The item path: the line names an item or an object,
                        -- and the world data says this creature can supply it.
                        matched = true
                        fromDatabase = true
                        dropRate = linkRate
                    elseif not name then
                        -- No format string resolved, so the line could not be
                        -- parsed into a name. Fall back to asking whether the
                        -- creature's name appears in it at all. Looser than an
                        -- exact name match -- "Night Web Spider" also matches a
                        -- "Young Night Web Spider" objective -- so it is only
                        -- ever reached when parsing is unavailable.
                        local textKey = UQ.NameKey(objective.text)
                        if textKey and string.find(textKey, unitKey, 1, true) then
                            matched = true
                        end
                    end

                    if matched then
                        table.insert(results, {
                            quest = quest,
                            objectiveIndex = objectiveIndex,
                            text = objective.text,
                            name = name,
                            have = have,
                            need = need,
                            finished = objective.finished and true or false,
                            fromDatabase = fromDatabase,
                            dropRate = dropRate,
                        })
                        if fromDatabase then
                            viaDatabase = viaDatabase + 1
                        else
                            direct = direct + 1
                        end
                    end
                end
                objectiveIndex = objectiveIndex + 1
            end
        end
        questIndex = questIndex + 1
    end

    if table.getn(results) == 0 then
        return nil
    end
    return results, direct, viaDatabase
end

-- The cached form. The tooltip poll asks about the same creature ten times a
-- second for as long as the mouse rests on it, and most creatures match
-- nothing, so the negative answer is worth remembering as much as the positive
-- one.
function ObjectiveMatch:FindForUnit(unitKey)
    if not unitKey then
        return nil
    end

    if self.cacheStamp ~= self.questStamp or self.cacheCount > MAX_CACHE_ENTRIES then
        self.cache = {}
        self.cacheCount = 0
        self.cacheStamp = self.questStamp
    end

    local cached = self.cache[unitKey]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached.results, cached.direct, cached.viaDatabase
    end

    local results, direct, viaDatabase = self:Resolve(unitKey)
    self.cacheCount = self.cacheCount + 1
    if not results then
        self.cache[unitKey] = false
        return nil
    end
    self.cache[unitKey] = { results = results, direct = direct, viaDatabase = viaDatabase }
    return results, direct, viaDatabase
end

function ObjectiveMatch:GetStatus()
    return {
        patternsResolved = self.patternsResolved,
        patternsExpected = table.getn(PATTERN_ORDER),
        questStamp = self.questStamp,
        cacheCount = self.cacheCount,
    }
end

-- Lifecycle -----------------------------------------------------------------

ObjectiveMatch.patternsResolved = 0

function ObjectiveMatch:OnEnable()
    local state = UQ:GetModule("QuestState")
    if state then
        state:AddListener(function()
            ObjectiveMatch.questStamp = ObjectiveMatch.questStamp + 1
        end)
    end

    -- Resolve the format strings once, at enable, so /uq status can report
    -- whether objective lines can be parsed at all on this client rather than
    -- leaving it to be discovered from a silent tooltip.
    local resolved = 0
    local index = 1
    local total = table.getn(PATTERN_ORDER)
    while index <= total do
        if GetPattern(PATTERN_ORDER[index]) then
            resolved = resolved + 1
        end
        index = index + 1
    end
    self.patternsResolved = resolved

    if resolved > 0 then
        UQ:DeclareCapability("questObjectivePatterns", "detected",
            "resolved " .. resolved .. " of " .. total .. " objective format strings "
            .. "(QUEST_MONSTERS_KILLED / QUEST_OBJECTS_FOUND / QUEST_ITEMS_NEEDED), which the client's own "
            .. "reference names as what GetQuestLogLeaderBoard formats objective text with. A kill "
            .. "objective's creature name is read straight out of the live log line from these, the way "
            .. "Interface/AddOns/pfQuest/map.lua does, so it needs no quest ID and no world-data record")
    else
        UQ:DeclareCapability("questObjectivePatterns", "missing",
            "none of QUEST_MONSTERS_KILLED / QUEST_OBJECTS_FOUND / QUEST_ITEMS_NEEDED is defined on this "
            .. "client, so an objective line cannot be split into a name and its counters. Matching falls "
            .. "back to asking whether the creature's name appears anywhere in the line, which matches a "
            .. "creature whose name is a prefix of another's too")
    end
end
