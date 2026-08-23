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
guards against. The section is capped by Config's per-section entry limit,
which is raised for the history sections specifically: they hold one entry per
quest a character has ever finished, so the working-set ceiling that fits
"quests I am tracking right now" would silently refuse most of a career.

Two smaller sections shadow the first, each recording WHERE a "done" came
from so it can be taken back on its own:

  * questHistoryManual -- every quest ID the player marked by hand, through
    WorldMapPins' shift-click (bulk) or Ctrl+click (single-quest) giver
    gesture. That split is what lets /uq resetmarked undo only what the player
    clicked, without also un-completing quests this addon correctly inferred
    from watching the log on its own.
  * questHistoryImported -- every quest ID that came in from another addon's
    saved history (Quest/PfQuestImport.lua). An import is a bulk claim about a
    career this addon never watched, sourced from data it cannot verify, so it
    has to be reversible as one act rather than one quest at a time.

The QUEST_REMOVED auto-detection below writes to neither. A quest can be in
both shadow sections at once (imported, then re-marked by hand); clearing
either one clears the "done" flag, which is the conservative reading -- a mark
the player asked to undo goes away whatever else also claimed it.
]]

local UQ = UnrealQuest
local QuestHistory = UQ:NewModule("QuestHistory")

local SECTION = "questHistory"
local MANUAL_SECTION = "questHistoryManual"
local IMPORTED_SECTION = "questHistoryImported"

local function Config()
    return UQ:GetModule("Config")
end

-- The keys of a section that are actually set, as an array. Collected before
-- anything is removed: nothing here deletes from a table while iterating it.
local function CollectMarked(section)
    local marked = {}
    local key, value
    for key, value in pairs(section) do
        if value == 1 then
            table.insert(marked, key)
        end
    end
    return marked
end

-- Clears one provenance section (manual or imported) and the matching "done"
-- flags, returning the quest IDs it cleared. Quests not recorded in that
-- section are untouched, whatever else marked them done.
local function ClearShadowSection(name)
    local config = Config()
    if not config then
        return {}
    end
    local reset = CollectMarked(config:GetSection(name))
    local index = 1
    local total = table.getn(reset)
    while index <= total do
        local id = reset[index]
        config:SetSectionEntry(name, id, nil)
        config:SetSectionEntry(SECTION, id, nil)
        index = index + 1
    end
    return reset
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
    config:SetSectionEntry(IMPORTED_SECTION, questId, nil)
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

-- The import counterpart: the same effect on the "done" flag, plus a record in
-- IMPORTED_SECTION so the whole import can be rolled back later.
--
-- Returns false when the quest was ALREADY done before this call, so an
-- importer can report how many quests it actually added rather than how many
-- it looked at -- and so rolling that import back cannot un-complete a quest
-- this addon had established on its own. A quest already recorded keeps
-- whatever provenance it had; the import does not claim it.
function QuestHistory:MarkDoneImported(questId)
    if type(questId) ~= "number" then
        return false
    end
    local config = Config()
    if not config then
        return false
    end
    if config:GetSection(SECTION)[questId] == 1 then
        return false
    end
    config:SetSectionEntry(IMPORTED_SECTION, questId, 1)
    return config:SetSectionEntry(SECTION, questId, 1)
end

-- Clears every quest ID recorded in MANUAL_SECTION from both sections and
-- returns how many were reset. Quests QuestHistory learned about on its own
-- (QUEST_REMOVED while complete) were never added to MANUAL_SECTION, so they
-- are left exactly as they were.
function QuestHistory:ResetManual()
    return ClearShadowSection(MANUAL_SECTION)
end

-- Clears every quest ID that came in through an import, from both sections,
-- and returns the list. Quests this addon inferred for itself and quests the
-- player marked by hand were never written to IMPORTED_SECTION, so they are
-- left exactly as they were -- an import can be undone without costing the
-- player the history they earned in this addon.
function QuestHistory:ResetImported()
    return ClearShadowSection(IMPORTED_SECTION)
end

-- How many quest IDs are recorded as having come from an import.
function QuestHistory:GetImportedCount()
    local config = Config()
    if not config then
        return 0
    end
    return table.getn(CollectMarked(config:GetSection(IMPORTED_SECTION)))
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
    return table.getn(CollectMarked(config:GetSection(SECTION)))
end

-- Clears every quest marked done at all, manual-gesture or auto-detected
-- alike, and returns how many. The blunt fallback for /uq resetmarked all,
-- for undoing a mark made before MANUAL_SECTION existed to track it.
function QuestHistory:ResetAll()
    local config = Config()
    if not config then
        return {}
    end
    local reset = CollectMarked(config:GetSection(SECTION))
    local index = 1
    local total = table.getn(reset)
    while index <= total do
        local id = reset[index]
        config:SetSectionEntry(MANUAL_SECTION, id, nil)
        config:SetSectionEntry(IMPORTED_SECTION, id, nil)
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
