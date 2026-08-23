--[[
UnrealQuest / Data/QuestMatch.lua

Resolves a quest log row to a quest ID in the bundled world data.

This module exists because of one hard client fact: the Unreal Azeroth client
exposes no quest ID API. Its documented Quest surface has sixty-four entries
and not one of them returns a quest ID, and the runtime compatibility database
has no record of such a call either. The static database, meanwhile, is keyed
by quest ID throughout. The join between them can only be the quest title, plus
whatever secondary signal is available without mutating client state.

Two consequences worth stating plainly, because they shape everything built on
top of this module:

  1. A match is a guess with a confidence, never an identity. Callers must
     handle "unmatched" and "ambiguous" as ordinary outcomes.
  2. The bundled data is Vanilla data and this realm runs a modified server,
     so a quest whose title the server changed will not match at all. That is
     expected, not a bug. Unmatched titles are recorded so the gap is visible
     rather than silent.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Match = UQ:NewModule("QuestMatch")

local MAX_RECORDED_MISSES = 100

Match.cache = {}
Match.missCount = 0

local function Database()
    return UQ:GetModule("Database")
end

local function CacheKey(titleKey, level)
    if type(level) == "number" then
        return titleKey .. "@" .. level
    end
    return titleKey .. "@?"
end

local function RecordMiss(title)
    local config = UQ:GetModule("Config")
    if not config or not config.store then
        return
    end
    if Match.missCount >= MAX_RECORDED_MISSES then
        return
    end
    if config:SetSectionEntry("unmatchedQuests", title, 1) then
        Match.missCount = Match.missCount + 1
    end
end

-- Result shape:
--   questId     resolved quest ID, or nil
--   confidence  "unique" | "levelDisambiguated" | "eligibilityDisambiguated"
--               | "textDisambiguated" | "objectiveDisambiguated"
--               | "textObjectiveDisambiguated" | "ambiguous" | "unmatched"
--   candidates  list of quest IDs sharing the title, when there is more than one
--   mapCandidates  candidates still possible after level and eligibility,
--                  used only for the map's safe-union fallback
--
-- questIndex is optional and is only spent when level and race/class both
-- fail to narrow a shared title to one record (see below); passing it lets a
-- same-title quest chain (e.g. "The Legend of Stalvan", 13 records under one
-- title) resolve via its logged detail text instead of staying ambiguous.
--
-- rawTitle is optional too and is the client's own spelling of the title from
-- before Client.CleanQuestTitle stripped a level decoration off it (see
-- Compatibility/ClientAPI.lua). It is non-nil only when cleaning changed
-- something, and it is looked up FIRST: whatever the client literally said is
-- the stronger claim, and trying it before the cleaned form means the cleaner
-- can never cost a match that would otherwise have been found. Only when the
-- client's own spelling is in no bucket at all does the cleaned title get its
-- turn.
function Match:Resolve(title, level, questIndex, rawTitle)
    local database = Database()
    if not database or not database.available then
        return nil, "unmatched", nil
    end
    if not database:IsIndexReady() then
        -- The index is still being built across driver ticks. Report honestly
        -- rather than caching a miss that would stick for the session.
        return nil, "indexing", nil
    end

    local titleKey = UQ.NameKey(title)
    if not titleKey then
        return nil, "unmatched", nil
    end

    -- Dropped when it says the same thing as the cleaned key, so the ordinary
    -- undecorated client costs exactly one lookup and one cache slot.
    local rawKey = nil
    if type(rawTitle) == "string" then
        rawKey = UQ.NameKey(rawTitle)
        if rawKey == titleKey then
            rawKey = nil
        end
    end

    -- Keyed on what the client actually handed over, not on the cleaned form:
    -- two different decorated titles can clean to the same string, and the
    -- cache must not let one of them answer for the other.
    local cacheKey = CacheKey(rawKey or titleKey, level)
    local cached = self.cache[cacheKey]
    if cached then
        return cached.questId, cached.confidence, cached.candidates, cached.mapCandidates
    end

    local candidates = nil
    if rawKey then
        candidates = database:FindQuestIdsByTitleKey(rawKey)
    end
    if not candidates or table.getn(candidates) == 0 then
        candidates = database:FindQuestIdsByTitleKey(titleKey)
    end
    local result

    if not candidates or table.getn(candidates) == 0 then
        -- Recorded under the client's own spelling: a miss list full of
        -- "[24] Weapons of Choice" is the symptom that names its own cause.
        RecordMiss(rawTitle or title)
        result = { questId = nil, confidence = "unmatched" }
    elseif table.getn(candidates) == 1 then
        result = { questId = candidates[1], confidence = "unique" }
    else
        local eligibility = UQ:GetModule("QuestEligibility")

        -- Same-level candidates first (unchanged from before), then within
        -- those the ones this character's race/class mask does not exclude.
        -- A quest already sitting in the log was offerable when accepted, so
        -- an excluded record cannot be the one actually in the log -- this is
        -- what tells apart same-title, same-level race/class variants such as
        -- "Garments of the Light" (5624 Human, 5625 Dwarf, both level 4).
        local levelMatch = nil
        local levelMatchCount = 0
        local refinedMatch = nil
        local refinedCount = 0
        local refinedCandidates = {}

        local index = 1
        local total = table.getn(candidates)
        while index <= total do
            local questId = candidates[index]
            local record = database:GetQuest(questId)

            local sameLevel = true
            if record and type(level) == "number" and type(record.lvl) == "number"
                and record.lvl ~= level then
                sameLevel = false
            end

            if sameLevel then
                levelMatch = questId
                levelMatchCount = levelMatchCount + 1

                if not eligibility or eligibility:MatchesRaceClass(record) then
                    refinedMatch = questId
                    refinedCount = refinedCount + 1
                    table.insert(refinedCandidates, questId)
                end
            end

            index = index + 1
        end

        if levelMatchCount == 1 then
            result = { questId = levelMatch, confidence = "levelDisambiguated", candidates = candidates }
        elseif refinedCount == 1 then
            result = { questId = refinedMatch, confidence = "eligibilityDisambiguated", candidates = candidates }
        else
            -- Still tied: same title, same level, same race/class mask -- the
            -- remaining case is a same-title chain quest (one step per record).
            -- Only the quest's own logged text can tell those apart, and
            -- reading it means moving the quest log selection, so it is only
            -- ever attempted here when QuestState first models the row. Text
            -- outcomes are deliberately not cached by title+level: a later
            -- same-title chain step must be allowed to read its own text.
            local textCandidates = candidates
            if refinedCount > 0 then
                textCandidates = refinedCandidates
            end

            local textMatch = nil
            local objectiveMatch = nil
            if type(questIndex) == "number" and Client and Client.GetQuestLogDetailText then
                local detailText = Client.GetQuestLogDetailText(questIndex)
                if detailText then
                    textMatch = self:Disambiguate(textCandidates, detailText)
                end
            end
            if type(questIndex) == "number" then
                objectiveMatch = self:DisambiguateObjectives(textCandidates, questIndex)
            end

            if textMatch and objectiveMatch and textMatch == objectiveMatch then
                result = {
                    questId = textMatch,
                    confidence = "textObjectiveDisambiguated",
                    candidates = candidates,
                }
            elseif textMatch and objectiveMatch and textMatch ~= objectiveMatch then
                -- Two independent live signals disagree. Neither is allowed
                -- to overrule the other: exposing either ID would be a guess.
                result = {
                    questId = nil,
                    confidence = "ambiguous",
                    candidates = candidates,
                    mapCandidates = textCandidates,
                }
            elseif textMatch then
                result = { questId = textMatch, confidence = "textDisambiguated", candidates = candidates }
            elseif objectiveMatch then
                result = {
                    questId = objectiveMatch,
                    confidence = "objectiveDisambiguated",
                    candidates = candidates,
                }
            else
                result = {
                    questId = nil,
                    confidence = "ambiguous",
                    candidates = candidates,
                    mapCandidates = textCandidates,
                }
            end
        end
    end

    -- Text-dependent outcomes must never be cached by title+level. Same-title
    -- chain steps can follow one another at the same level in one session;
    -- caching the first step's text result would assign that ID to the next
    -- step without reading its description. QuestState resolves a newly seen
    -- row once, so leaving these two outcomes uncached does not add poll-time
    -- selection churn.
    if result.confidence ~= "textDisambiguated"
        and result.confidence ~= "objectiveDisambiguated"
        and result.confidence ~= "textObjectiveDisambiguated"
        and result.confidence ~= "ambiguous" then
        self.cache[cacheKey] = result
    end
    return result.questId, result.confidence, result.candidates, result.mapCandidates
end

-- True when needle's NameKey occurs inside haystack's NameKey. NameKey only
-- ever emits ASCII letters/digits and raw high bytes (see Core/Namespace.lua),
-- never a Lua pattern-magic character, so a plain string.find is a safe
-- substring test without needing the "plain" argument.
local function KeyContains(haystack, needle)
    if not haystack or not needle or needle == "" then
        return false
    end
    return string.find(haystack, needle) ~= nil
end

-- Render the substitutions this client's quest text applies before Lua sees
-- GetQuestLogQuestText. pfQuest is the upstream prior art for the known token
-- set ($N/$C/$R/$B/$G); unlike pfQuest, UnrealQuest does not pick the first
-- best-scoring ID. The documented UnitSex selects the gender branch when it is
-- readable; both are tried as a safe fallback. A result is accepted only when
-- one candidate is uniquely compatible with the live description.
local function ReplaceToken(text, pattern, value)
    if type(value) ~= "string" or value == "" then
        return text
    end
    return string.gsub(text, pattern, function() return value end)
end

local function RenderQuestText(text, genderBranch)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    if Client then
        if Client.GetPlayerName then
            text = ReplaceToken(text, "%$[Nn]", Client.GetPlayerName())
        end
        if Client.GetPlayerClass then
            local className = Client.GetPlayerClass()
            text = ReplaceToken(text, "%$[Cc]", className)
        end
        if Client.GetPlayerRace then
            text = ReplaceToken(text, "%$[Rr]", Client.GetPlayerRace())
        end
    end

    -- NameKey removes whitespace, so an empty replacement is equivalent to
    -- the client's newline while avoiding any formatting assumption.
    text = string.gsub(text, "%$[Bb]", "")
    text = string.gsub(text, "%$[Gg]([^:;]+):([^;]+);", function(male, female)
        if genderBranch == 2 then
            return female
        end
        return male
    end)
    return UQ.NameKey(text)
end

local function QuestTextKeys(text)
    local keys = {}
    local male = RenderQuestText(text, 1)
    local female = RenderQuestText(text, 2)
    local sex = nil
    if Client and Client.GetPlayerSex then
        sex = Client.GetPlayerSex()
    end
    if sex == 2 then
        if male then
            table.insert(keys, male)
        end
    elseif sex == 3 then
        if female then
            table.insert(keys, female)
        end
    else
        if male then
            table.insert(keys, male)
        end
        if female and female ~= male then
            table.insert(keys, female)
        end
    end
    return keys
end

local OBJECTIVE_RELATION_FOR_TYPE = {
    monster = "U",
    item = "I",
    gobject = "O",
}

local function AddObjectiveKey(keys, name)
    local key = UQ.NameKey(name)
    if key then
        keys[key] = true
    end
end

local function CandidateObjectiveKeys(database, questId)
    local byType = {
        monster = {},
        item = {},
        gobject = {},
    }
    local relation = database:GetQuestObjectiveSources(questId)
    if type(relation) ~= "table" then
        return byType
    end

    local _, sourceId
    if type(relation.U) == "table" then
        for _, sourceId in pairs(relation.U) do
            AddObjectiveKey(byType.monster, database:GetUnitName(sourceId))
        end
    end
    if type(relation.I) == "table" then
        for _, sourceId in pairs(relation.I) do
            AddObjectiveKey(byType.item, database:GetItemName(sourceId))
        end
    end
    if type(relation.O) == "table" then
        for _, sourceId in pairs(relation.O) do
            AddObjectiveKey(byType.gobject, database:GetObjectName(sourceId))
        end
    end
    return byType
end

-- Exact objective evidence for a still-ambiguous title. This deliberately
-- does not compare prose or use fuzzy distance: every live objective line
-- must parse through the client's documented format, every parsed name must
-- exactly match the same relation type in the bundled candidate, and exactly
-- one candidate must satisfy the complete live set. Missing/unparsed evidence
-- returns nil rather than excluding a candidate on an assumption.
function Match:DisambiguateObjectives(candidates, questIndex)
    local database = Database()
    local parser = UQ:GetModule("ObjectiveMatch")
    if not database or not candidates or type(questIndex) ~= "number"
        or not parser or not parser.ParseLine or not Client
        or not Client.GetObjectiveCount or not Client.GetObjective then
        return nil
    end

    local count = Client.GetObjectiveCount(questIndex)
    if type(count) ~= "number" or count < 1 then
        return nil
    end

    local live = {
        monster = {},
        item = {},
        gobject = {},
    }
    local index = 1
    while index <= count do
        local text, objectiveType = Client.GetObjective(questIndex, index)
        if not OBJECTIVE_RELATION_FOR_TYPE[objectiveType] then
            return nil
        end
        local name = parser:ParseLine(text, objectiveType)
        local key = UQ.NameKey(name)
        if not key then
            return nil
        end
        live[objectiveType][key] = true
        index = index + 1
    end

    local hit = nil
    local hits = 0
    local candidateIndex = 1
    local candidateTotal = table.getn(candidates)
    while candidateIndex <= candidateTotal do
        local questId = candidates[candidateIndex]
        local keys = CandidateObjectiveKeys(database, questId)
        local matches = true
        local objectiveType, names, nameKey
        for objectiveType, names in pairs(live) do
            for nameKey in pairs(names) do
                if not keys[objectiveType][nameKey] then
                    matches = false
                end
            end
        end
        if matches then
            hit = questId
            hits = hits + 1
        end
        candidateIndex = candidateIndex + 1
    end

    if hits == 1 then
        return hit
    end
    return nil
end

-- Second-stage disambiguation for an ambiguous title, called automatically
-- from Resolve above once level and race/class both fail to narrow the field,
-- and available for a caller to invoke directly with its own text.
--
-- GetQuestLogQuestText is documented (docs/CLIENT-COMPATIBILITY.md, "Quest
-- log") to return only the selected quest's description. Known live tokens
-- are rendered before comparison. Exact normalized matches win first; only
-- when none exists is the older containment allowance considered. Objectives
-- are deliberately excluded because this client does not return them here.
-- A tie or missing text remains honestly "ambiguous", and map renderers draw
-- the safe candidate union instead of inventing an ID.
function Match:Disambiguate(candidates, logText)
    local database = Database()
    if not database or not candidates then
        return nil
    end
    local wanted = UQ.NameKey(logText)
    if not wanted then
        return nil
    end

    local index = 1
    local total = table.getn(candidates)
    local exactHit = nil
    local exactHits = 0
    local containsHit = nil
    local containsHits = 0
    while index <= total do
        local questId = candidates[index]
        local text = database:GetQuestText(questId)
        local keys = QuestTextKeys(text and text.D)
        local keyIndex = 1
        local keyTotal = table.getn(keys)
        local exact = false
        local contains = false
        while keyIndex <= keyTotal do
            local key = keys[keyIndex]
            if key == wanted then
                exact = true
            elseif KeyContains(wanted, key) then
                contains = true
            end
            keyIndex = keyIndex + 1
        end
        if exact then
            exactHit = questId
            exactHits = exactHits + 1
        elseif contains then
            containsHit = questId
            containsHits = containsHits + 1
        end
        index = index + 1
    end

    if exactHits == 1 then
        return exactHit
    end
    if exactHits == 0 and containsHits == 1 then
        return containsHit
    end
    return nil
end

function Match:ClearCache()
    self.cache = {}
end

function Match:GetUnmatchedCount()
    return self.missCount
end
