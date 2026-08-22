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
--   confidence  "unique" | "levelDisambiguated" | "ambiguous" | "unmatched"
--   candidates  list of quest IDs sharing the title, when there is more than one
function Match:Resolve(title, level)
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

    local cacheKey = CacheKey(titleKey, level)
    local cached = self.cache[cacheKey]
    if cached then
        return cached.questId, cached.confidence, cached.candidates
    end

    local candidates = database:FindQuestIdsByTitleKey(titleKey)
    local result

    if not candidates or table.getn(candidates) == 0 then
        RecordMiss(title)
        result = { questId = nil, confidence = "unmatched" }
    elseif table.getn(candidates) == 1 then
        result = { questId = candidates[1], confidence = "unique" }
    else
        local matched = nil
        local matchedCount = 0
        local index = 1
        local total = table.getn(candidates)
        while index <= total do
            local questId = candidates[index]
            local record = database:GetQuest(questId)
            if record and type(level) == "number" and record.lvl == level then
                matched = questId
                matchedCount = matchedCount + 1
            end
            index = index + 1
        end

        if matchedCount == 1 then
            result = { questId = matched, confidence = "levelDisambiguated", candidates = candidates }
        else
            result = { questId = nil, confidence = "ambiguous", candidates = candidates }
        end
    end

    self.cache[cacheKey] = result
    return result.questId, result.confidence, result.candidates
end

-- Second-stage disambiguation for an ambiguous title.
--
-- The caller supplies the quest's objectives text; this module never fetches it
-- itself, because the only way to read it is GetQuestLogQuestText, which
-- requires changing the quest log selection that the native Quest Log window
-- also reads. That is a deliberate action for a caller to take on demand, not
-- something a polling loop should do.
function Match:Disambiguate(candidates, objectivesText)
    local database = Database()
    if not database or not candidates then
        return nil
    end
    local wanted = UQ.NameKey(objectivesText)
    if not wanted then
        return nil
    end

    local index = 1
    local total = table.getn(candidates)
    local hit = nil
    local hits = 0
    while index <= total do
        local questId = candidates[index]
        local text = database:GetQuestText(questId)
        if text and UQ.NameKey(text.O) == wanted then
            hit = questId
            hits = hits + 1
        end
        index = index + 1
    end

    if hits == 1 then
        return hit
    end
    return nil
end

function Match:ClearCache()
    self.cache = {}
end

function Match:GetUnmatchedCount()
    return self.missCount
end
