--[[
UnrealQuest / Quest/QuestHistory.lua

Locally-tracked quest completions, keyed by database quest ID.

This client exposes no quest-ID-returning call and no completed-quest history
call at all (docs/CLIENT-COMPATIBILITY.md, "No quest ID API"). A "still to
take" map marker can therefore never know about a quest the player finished
before this addon was first loaded -- there is nothing to ask the server or
the client. What it CAN do is remember, from here on, every quest it
personally watches disappear from the quest log while complete, plus whatever
the player marks by hand. That is the full extent of what "done" means here.

Storage goes through Config's existing shallow section store (SavedVariables),
keyed by the numeric quest ID -- never a title, path or other unsafe string --
so QuestHistory carries no persistence risk beyond what Config already
guards against. The section is capped by Config's own MAX_SET_ENTRIES.

A second, smaller section shadows the first: every quest ID marked done
through the player's own hand -- WorldMapPins' shift-click (bulk) or
Ctrl+click (single-quest) giver gesture -- is also recorded here. The
QUEST_REMOVED auto-detection above never writes to it. That split is what lets
/uq resetmarked undo only what the player clicked, without also un-completing
quests this addon correctly inferred from watching the log on its own.
]]

local UQ = UnrealQuest
local QuestHistory = UQ:NewModule("QuestHistory")

local SECTION = "questHistory"
local MANUAL_SECTION = "questHistoryManual"

local function Config()
    return UQ:GetModule("Config")
end

function QuestHistory:IsDone(questId)
    if type(questId) ~= "number" then
        return false
    end
    local config = Config()
    if not config then
        return false
    end
    return config:GetSection(SECTION)[questId] == 1
end

function QuestHistory:MarkDone(questId)
    if type(questId) ~= "number" then
        return false
    end
    local config = Config()
    if not config then
        return false
    end
    return config:SetSectionEntry(SECTION, questId, 1)
end

function QuestHistory:MarkNotDone(questId)
    if type(questId) ~= "number" then
        return false
    end
    local config = Config()
    if not config then
        return false
    end
    config:SetSectionEntry(MANUAL_SECTION, questId, nil)
    return config:SetSectionEntry(SECTION, questId, nil)
end

-- The manual-gesture counterpart of MarkDone: same effect on the "done" flag,
-- plus a record in MANUAL_SECTION so /uq resetmarked can find it again later.
function QuestHistory:MarkDoneManually(questId)
    if type(questId) ~= "number" then
        return false
    end
    local config = Config()
    if not config then
        return false
    end
    config:SetSectionEntry(MANUAL_SECTION, questId, 1)
    return config:SetSectionEntry(SECTION, questId, 1)
end

-- Clears every quest ID recorded in MANUAL_SECTION from both sections and
-- returns how many were reset. Quests QuestHistory learned about on its own
-- (QUEST_REMOVED while complete) were never added to MANUAL_SECTION, so they
-- are left exactly as they were.
function QuestHistory:ResetManual()
    local config = Config()
    if not config then
        return {}
    end
    local manual = config:GetSection(MANUAL_SECTION)
    local reset = {}
    local questId, value
    for questId, value in pairs(manual) do
        if value == 1 then
            table.insert(reset, questId)
        end
    end
    local index = 1
    local total = table.getn(reset)
    while index <= total do
        local id = reset[index]
        config:SetSectionEntry(MANUAL_SECTION, id, nil)
        config:SetSectionEntry(SECTION, id, nil)
        index = index + 1
    end
    return reset
end

-- Every quest ID marked done, manual or not. Used to size the gap between
-- what ResetManual can see and what is actually recorded -- MANUAL_SECTION
-- only started being written the moment MarkDoneManually shipped, so a quest
-- shift-clicked before that update is done in SECTION with no matching
-- MANUAL_SECTION entry, and ResetManual alone cannot find it.
function QuestHistory:GetDoneCount()
    local config = Config()
    if not config then
        return 0
    end
    local section = config:GetSection(SECTION)
    local count = 0
    local questId, value
    for questId, value in pairs(section) do
        if value == 1 then
            count = count + 1
        end
    end
    return count
end

-- Clears every quest marked done at all, manual-gesture or auto-detected
-- alike, and returns how many. The blunt fallback for /uq resetmarked all,
-- for undoing a mark made before MANUAL_SECTION existed to track it.
function QuestHistory:ResetAll()
    local config = Config()
    if not config then
        return {}
    end
    local section = config:GetSection(SECTION)
    local reset = {}
    local questId, value
    for questId, value in pairs(section) do
        if value == 1 then
            table.insert(reset, questId)
        end
    end
    local index = 1
    local total = table.getn(reset)
    while index <= total do
        local id = reset[index]
        config:SetSectionEntry(MANUAL_SECTION, id, nil)
        config:SetSectionEntry(SECTION, id, nil)
        index = index + 1
    end
    return reset
end

-- A quest that was complete (ready to hand in) on its last scan and then
-- disappeared from the log almost always means it was turned in rather than
-- abandoned. This is a heuristic, not a certainty; shift-clicking a marker
-- lets the player correct it either way.
function QuestHistory:OnEnable()
    local questState = UQ:GetModule("QuestState")
    if questState then
        questState:AddListener(function(event, quest)
            if event == "QUEST_REMOVED" and quest and quest.isComplete == 1
                and type(quest.questId) == "number" then
                QuestHistory:MarkDone(quest.questId)
            end
        end)
    end
end
