--[[
UnrealQuest / Quest/QuestItems.lua

Which carried item a quest wants the player to USE, for the tracker's
quest-item button (Quest/TrackerFrame.lua).

An item qualifies when all three hold:

  * the bundled data names it for the quest: obj.IR (an item used on a unit or
    object) first, then obj.I (an objective item, e.g. a sample container);
  * Quest/BagItems.lua reports it carried -- true, not the nil of an unread
    bag, which draws nothing;
  * GetItemSpell names a Use spell for it, so letters and loot never get a
    button (measured: 18 named, 9 nil over one bag,
    items.item_spell_cooldown_getters_questitem_v1).

A quest match is a hypothesis (no quest ID API). A resolved match is asked
alone; an ambiguous one asks every candidate, which is safe here because the
item must also be in the bag and usable. An unmatched quest gets no button.

Using it is a plain addon click (Client.UseBagItem), measured to work in and
out of combat (items.addon_item_use_questitem_v2).
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestItems = UQ:NewModule("QuestItems")

-- Match confidences that name one quest. Same set as the world map's
-- IsResolvedQuest (Map/WorldMapPins.lua).
local RESOLVED = {
    unique = true,
    levelDisambiguated = true,
    historyDisambiguated = true,
    eligibilityDisambiguated = true,
    textDisambiguated = true,
    objectiveDisambiguated = true,
    textObjectiveDisambiguated = true,
}

-- questId -> ordered list of candidate item IDs. Static bundled data.
local itemsByQuest = {}
-- itemId -> true once GetItemSpell named a Use spell. Only a yes is kept: a
-- nil may just be an item the client has not cached yet, and asking again is
-- one call per carried candidate.
local usable = {}

QuestItems.uses = 0
QuestItems.useFailures = 0

local function CandidateItems(questId)
    local cached = itemsByQuest[questId]
    if cached then
        return cached
    end
    local list = {}
    local database = UQ:GetModule("Database")
    local relation = database and database:GetQuestObjectiveSources(questId)
    if type(relation) == "table" then
        local seen = {}
        local keys = { "IR", "I" }
        local k = 1
        while k <= 2 do
            local ids = relation[keys[k]]
            if type(ids) == "table" then
                local index = 1
                local total = table.getn(ids)
                while index <= total do
                    local itemId = ids[index]
                    if type(itemId) == "number" and not seen[itemId] then
                        seen[itemId] = true
                        table.insert(list, itemId)
                    end
                    index = index + 1
                end
            end
            k = k + 1
        end
    end
    itemsByQuest[questId] = list
    return list
end

local function IsUsable(itemId)
    if usable[itemId] then
        return true
    end
    if Client.GetItemUseSpell(itemId) ~= nil then
        usable[itemId] = true
        return true
    end
    return false
end

local function FirstUsableCarried(questId, bagItems)
    local list = CandidateItems(questId)
    local index = 1
    local total = table.getn(list)
    while index <= total do
        local itemId = list[index]
        if bagItems:Carries(itemId) == true and IsUsable(itemId) then
            return itemId
        end
        index = index + 1
    end
    return nil
end

-- The item ID to put on this quest's tracker row, or nil.
function QuestItems:GetUseItem(quest)
    if type(quest) ~= "table" or quest.isComplete == 1 then
        return nil
    end
    if not UQ:HasCapability("itemUse") then
        return nil
    end
    local bagItems = UQ:GetModule("BagItems")
    if not bagItems then
        return nil
    end
    if type(quest.questId) == "number" and RESOLVED[quest.matchConfidence or ""] then
        return FirstUsableCarried(quest.questId, bagItems)
    end
    if quest.matchConfidence ~= "ambiguous" then
        return nil
    end
    local candidates = quest.matchCandidates
    if type(candidates) ~= "table" then
        return nil
    end
    local index = 1
    local total = table.getn(candidates)
    while index <= total do
        local questId = candidates[index]
        if type(questId) == "number" then
            local itemId = FirstUsableCarried(questId, bagItems)
            if itemId then
                return itemId
            end
        end
        index = index + 1
    end
    return nil
end

-- From the button's click handler only.
function QuestItems:Use(itemId)
    if Client.UseBagItem(itemId) then
        self.uses = self.uses + 1
        return true
    end
    self.useFailures = self.useFailures + 1
    return false
end

-- Seconds left on the item's cooldown; 0 when ready, nil when unknown.
function QuestItems:CooldownRemaining(itemId)
    local remaining = Client.GetItemCooldownRemaining(itemId)
    return remaining
end
