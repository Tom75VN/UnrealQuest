--[[
UnrealQuest / Quest/MainQuest.lua

The "main quest": the one quest the player is currently doing, and the one the
HUD waypoint points at.

This is a selection layer over the quest model, nothing more. It owns no
locations, no widgets and no client calls beyond the quest log the model
already polls -- the target point comes from Data/QuestTarget.lua and the
marker from HUD/Waypoint.lua, so this file stays about identity alone.

Three constraints shape it:

1. **Identity is a normalized title, because this client has no quest ID API.**
   The main quest is remembered as its `titleKey` (Core/Namespace.lua's
   NameKey), the same key Quest/QuestState.lua stores quests under, and never
   as a quest log index -- indices shift the moment any quest is accepted or
   turned in, and a remembered index would silently come back pointing at a
   different quest. A titleKey is alphanumeric by construction, so it also
   satisfies the rule that nothing bearing a backslash may be persisted.

2. **A quest vanishing from the log is not proof it was turned in.** A
   collapsed quest log header hides its quests from GetNumQuestLogEntries
   entirely, so a snapshot taken while any header is collapsed is incomplete.
   Clearing the main quest from an incomplete snapshot would silently drop the
   player's selection every time they collapsed a header. Selection is
   therefore only ever cleared from a complete snapshot, the same rule
   Quest/QuestState.lua and Quest/Tracker.lua already apply to removals.

3. **The selection outlives a reload.** The native watch list does not survive
   one here, which is why Tracker re-applies it; the main quest is stored the
   same way and restored the same way, on the driver rather than once, because
   the quest log may not be populated when the addon enables.
]]

local UQ = UnrealQuest
local MainQuest = UQ:NewModule("MainQuest")

local STORE_KEY = "mainQuestTitleKey"
-- At the default 0.5s poll this is ten seconds of waiting for the quest
-- log to populate before an absent quest is believed to be absent.
local MAX_RESTORE_ATTEMPTS = 20

MainQuest.titleKey = nil
MainQuest.restored = false
MainQuest.listeners = {}
MainQuest.selectionCount = 0
MainQuest.restoreAttempts = 0

local function Config()
    return UQ:GetModule("Config")
end

local function QuestState()
    return UQ:GetModule("QuestState")
end

local function Tracker()
    return UQ:GetModule("Tracker")
end

-- Listeners ------------------------------------------------------------------
-- Same shape as QuestState's: plain callbacks, each guarded, so one bad
-- listener cannot stop the others from hearing about a selection change.

function MainQuest:AddListener(callback)
    if type(callback) == "function" then
        table.insert(self.listeners, callback)
    end
end

function MainQuest:Notify(event)
    local index = 1
    local total = table.getn(self.listeners)
    while index <= total do
        local ok, err = pcall(self.listeners[index], event, self.titleKey)
        if not ok then
            UQ:Debug("main quest listener failed: " .. tostring(err))
        end
        index = index + 1
    end
end

-- Selection ------------------------------------------------------------------

function MainQuest:Get()
    return self.titleKey
end

function MainQuest:IsMain(titleKey)
    return titleKey ~= nil and titleKey == self.titleKey
end

-- The live quest record for the selection, or nil when the selected quest is
-- not currently in the log. Nil here is an ordinary state, not an error: the
-- player may have the selection restored before the log has populated.
function MainQuest:GetQuest()
    if not self.titleKey then
        return nil
    end
    local questState = QuestState()
    if not questState then
        return nil
    end
    return questState:GetQuest(self.titleKey)
end

function MainQuest:Persist()
    local config = Config()
    if not config then
        return
    end
    -- A titleKey is alphanumeric by construction (NameKey strips everything
    -- else), so it can never carry the backslash this client's SavedVariables
    -- writer mangles. Cleared selection stores the empty string rather than
    -- nil: Config:Get falls back to the default for a nil, which would make
    -- "cleared" indistinguishable from "never set".
    config:Set(STORE_KEY, self.titleKey or "")
end

-- Sets the main quest, or clears it when the same quest is selected again.
--
-- Re-selecting to clear is the whole reason plain left-click on a quest log
-- row is safe to use for this: without it the only way to stop following a
-- quest would be a slash command, and with it the gesture is its own toggle.
function MainQuest:Toggle(titleKey)
    if titleKey and titleKey == self.titleKey then
        return self:Clear("toggled off")
    end
    return self:Set(titleKey)
end

function MainQuest:Set(titleKey)
    if type(titleKey) ~= "string" or titleKey == "" then
        return false, "invalidKey"
    end
    if titleKey == self.titleKey then
        return true, "unchanged"
    end

    self.titleKey = titleKey
    self.selectionCount = self.selectionCount + 1
    self:Persist()
    self:Notify("MAIN_QUEST_CHANGED")

    -- Following a quest and watching it are separate ideas here, and the
    -- default keeps them separate. With plain-click selection, auto-tracking
    -- would add every quest browsed to the tracked set. Opt in with
    -- mainQuestAutoTrack.
    local config = Config()
    if config and config:Get("mainQuestAutoTrack") then
        local tracker = Tracker()
        local quest = self:GetQuest()
        if tracker and quest then
            pcall(function() tracker:Track(quest) end)
        end
    end

    return true, "set"
end

function MainQuest:Clear(reason)
    if not self.titleKey then
        return false, "noSelection"
    end
    UQ:Debug("main quest cleared: " .. tostring(reason or "unspecified"))
    self.titleKey = nil
    self:Persist()
    self:Notify("MAIN_QUEST_CLEARED")
    return true, "cleared"
end

-- Resolves a free-text argument to a quest in the log: an exact quest log
-- index, or a case-insensitive title fragment. Mirrors how /uq track already
-- accepts either, so the two commands do not need two mental models.
--
-- Returns titleKey, quest, or nil plus a reason and, for an ambiguous
-- fragment, the list of titles that matched.
function MainQuest:ResolveTarget(argument)
    local questState = QuestState()
    if not questState then
        return nil, "noQuestModel"
    end

    local trimmed = UQ.Trim(argument)
    if not trimmed or trimmed == "" then
        return nil, "noTarget"
    end

    local quests = questState:GetOrderedQuests()

    local wanted = tonumber(trimmed)
    if wanted then
        local index = 1
        local total = table.getn(quests)
        while index <= total do
            local quest = quests[index]
            if quest.index == wanted then
                return quest.titleKey, quest
            end
            index = index + 1
        end
        return nil, "noQuestAtIndex"
    end

    local needle = string.lower(trimmed)
    local matches = {}
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        local title = quest.title and string.lower(quest.title) or ""
        if string.find(title, needle, 1, true) then
            table.insert(matches, quest)
        end
        index = index + 1
    end

    local matchTotal = table.getn(matches)
    if matchTotal == 1 then
        return matches[1].titleKey, matches[1]
    elseif matchTotal == 0 then
        return nil, "noMatch"
    end

    local titles = {}
    index = 1
    while index <= matchTotal do
        table.insert(titles, matches[index].title)
        index = index + 1
    end
    return nil, "ambiguous", titles
end

-- Validation -----------------------------------------------------------------

-- Drops the selection once the quest is genuinely gone from the log, and never
-- before. Runs on the driver rather than on an event, because no quest event
-- is trusted here to be the mechanism.
function MainQuest:Validate()
    if not self.titleKey then
        return
    end
    local questState = QuestState()
    if not questState then
        return
    end
    -- A snapshot taken while a quest log header was collapsed does not list
    -- the quests under it. Clearing from one would drop the player's selection
    -- every time they collapsed a header, which is indistinguishable from the
    -- addon forgetting on its own.
    if not questState.complete then
        return
    end
    if questState:GetQuest(self.titleKey) then
        return
    end
    -- Restoration has not necessarily finished when the first complete
    -- snapshot lands, and clearing here would erase the very selection the
    -- restore is about to re-apply.
    if not self.restored then
        return
    end
    self:Clear("quest left the quest log")
end

-- Restoration ----------------------------------------------------------------

-- Reads the remembered selection back.
--
-- Retries on the driver instead of running once, because the quest log may
-- still be empty when the addon enables and a single early attempt would
-- silently give up. The retry is BOUNDED: an unpopulated log and a genuinely
-- empty one look identical from here, so after MAX_RESTORE_ATTEMPTS the log is
-- taken at face value. Retrying forever would leave `restored` false forever,
-- which in turn leaves Validate permanently disarmed -- the selection could
-- then never be cleared for the rest of the session.
function MainQuest:Restore()
    if self.restored then
        return
    end
    local config = Config()
    local questState = QuestState()
    if not config or not questState then
        return
    end

    local stored = config:Get(STORE_KEY)
    if type(stored) ~= "string" or stored == "" then
        -- Nothing was remembered. That is a finished restoration, not a
        -- pending one: leaving it pending would keep Validate disarmed for the
        -- whole session.
        self.restored = true
        return
    end

    if questState:GetQuest(stored) then
        self.titleKey = stored
        self.restored = true
        self:Notify("MAIN_QUEST_CHANGED")
        UQ:Debug("main quest restored: " .. stored)
        return
    end

    self.restoreAttempts = (self.restoreAttempts or 0) + 1

    -- The quest is not in the log. Only believe that once the log has been
    -- seen whole -- a collapsed header hides quests entirely -- or once the
    -- retries run out.
    local settled = questState.complete and questState:GetQuestCount() > 0
    if settled or self.restoreAttempts >= MAX_RESTORE_ATTEMPTS then
        self.restored = true
        self.titleKey = stored
        self:Clear("remembered quest is no longer in the log")
    end
end

-- Reporting ------------------------------------------------------------------

function MainQuest:GetReport()
    local report = {
        titleKey = self.titleKey,
        restored = self.restored,
        selections = self.selectionCount,
    }
    local quest = self:GetQuest()
    if quest then
        report.title = quest.title
        report.level = quest.level
        report.index = quest.index
        report.questId = quest.questId
        report.matchConfidence = quest.matchConfidence
        report.isComplete = quest.isComplete
    end
    return report
end

-- Lifecycle ------------------------------------------------------------------

function MainQuest:OnInit()
    if not UQ:IsFeatureEnabled("mainQuestWaypoint") then
        -- No capability is declared while the layer is gated off. /uq status
        -- reports what the addon is actually exercising on this client, and a
        -- capability claimed by a layer that registers nothing would be a lie
        -- of exactly the kind the registry exists to prevent. The gate itself
        -- is what /uq status prints instead.
        return
    end
    UQ:DeclareCapability("mainQuestSelection", "verified",
        "selection is remembered as the quest's normalized title, the same key the quest model uses, "
        .. "because this client exposes no quest ID API and a remembered quest log index would come "
        .. "back pointing at a different quest after any accept or turn-in")
end

function MainQuest:OnEnable()
    if not UQ:IsFeatureEnabled("mainQuestWaypoint") then
        -- Returning here is the whole disable: no mainquest.restore and no
        -- mainquest.validate job is ever scheduled, so this module costs
        -- nothing per driver tick. The selection is also never restored from
        -- SavedVariables, so a key persisted before the layer was gated off
        -- stays on disk, untouched and ready, rather than being cleared.
        return
    end

    local driver = UQ:GetModule("Driver")
    local config = Config()
    local interval = (config and config:Get("pollInterval")) or 0.5

    if driver then
        driver:Schedule("mainquest.restore", interval, function()
            if MainQuest.restored then
                driver:Unschedule("mainquest.restore")
                return
            end
            MainQuest:Restore()
        end)
        driver:Schedule("mainquest.validate", interval, function()
            MainQuest:Validate()
        end)
    end
end
