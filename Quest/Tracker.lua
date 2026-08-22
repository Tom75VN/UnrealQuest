--[[
UnrealQuest / Quest/Tracker.lua

Wrapper over the client's quest watch list, plus the persistence the client
does not provide.

Client facts this is built on, all from measured or in-game confirmed evidence:

  * AddQuestWatch, RemoveQuestWatch and IsQuestWatched share one index space:
    the raw GetQuestLogTitle index, headers included. They round-trip cleanly.
  * The watch list is client state that does NOT survive a UI reload here.
    After /reload the client reports zero watched quests even for a quest the
    player was tracking. Persisting and reapplying the set is the addon's job.
  * The client caps the watch list at five quests.

Two ordering hazards are handled explicitly, because getting either wrong
produces a bug that looks exactly like "the client does not persist tracking":

  1. The quest log may not be populated when the addon enables, so restoration
     retries on the driver instead of running once.
  2. The first sync pass can run before restoration finishes. Remembering a
     tracked quest is never gated, but forgetting one is gated behind the
     restored flag, so an early sync can never erase the remembered set.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Tracker = UQ:NewModule("Tracker")

local SECTION = "trackedQuests"
local RESTORE_INTERVAL = 1.0
local RESTORE_ATTEMPTS = 20

Tracker.restored = false
Tracker.attempts = 0

local function Config()
    return UQ:GetModule("Config")
end

local function State()
    return UQ:GetModule("QuestState")
end

-- Remembered set ------------------------------------------------------------
-- Keyed by quest title. The quest log index shifts constantly and there is no
-- quest ID to key on, so the title is the only stable handle available.

function Tracker:Remember(title)
    local config = Config()
    if not config then
        return
    end
    config:SetSectionEntry(SECTION, title, 1)
end

function Tracker:Forget(title)
    local config = Config()
    if not config then
        return
    end
    -- Never forget before restoration has completed: an early sync pass would
    -- otherwise wipe exactly the set it is meant to restore.
    if not self.restored then
        return
    end
    config:SetSectionEntry(SECTION, title, nil)
end

function Tracker:IsRemembered(title)
    local config = Config()
    if not config then
        return false
    end
    local section = config:GetSection(SECTION)
    if not section then
        return false
    end
    return section[title] ~= nil
end

-- Live watch state ----------------------------------------------------------

function Tracker:IsTracked(quest)
    if not quest or not quest.index then
        return false
    end
    local watched = Client.IsQuestWatched(quest.index)
    if watched == nil then
        return false
    end
    return watched
end

function Tracker:Track(quest)
    if not quest or not quest.index then
        return false
    end
    if Client.GetWatchCount() >= Client.MAX_WATCHES and not self:IsTracked(quest) then
        UQ:Print("the client allows at most " .. Client.MAX_WATCHES .. " tracked quests")
        return false
    end
    if not Client.AddQuestWatch(quest.index) then
        return false
    end
    self:Remember(quest.title)
    Client.RefreshQuestWatch()
    return true
end

function Tracker:Untrack(quest)
    if not quest or not quest.index then
        return false
    end
    if not Client.RemoveQuestWatch(quest.index) then
        return false
    end
    self:Forget(quest.title)
    Client.RefreshQuestWatch()
    return true
end

function Tracker:Toggle(quest)
    if self:IsTracked(quest) then
        return self:Untrack(quest)
    end
    return self:Track(quest)
end

-- Restoration ---------------------------------------------------------------

function Tracker:Restore()
    local config = Config()
    local state = State()
    if not config or not state then
        self.restored = true
        return true
    end

    self.attempts = self.attempts + 1

    local section = config:GetSection(SECTION)
    if not section then
        self.restored = true
        return true
    end

    -- Nothing remembered: restoration is trivially complete.
    local anyRemembered = false
    for _ in pairs(section) do
        anyRemembered = true
        break
    end
    if not anyRemembered then
        self.restored = true
        return true
    end

    -- An empty or partial quest log means the client has not populated it yet.
    -- Keep retrying rather than concluding the remembered quests are gone.
    if state:GetQuestCount() == 0 or not state:IsComplete() then
        if self.attempts >= RESTORE_ATTEMPTS then
            self.restored = true
            UQ:Debug("tracking restore gave up after " .. self.attempts .. " attempts")
            return true
        end
        return false
    end

    local quests = state:GetOrderedQuests()
    local index = 1
    local total = table.getn(quests)
    local applied = 0
    while index <= total do
        local quest = quests[index]
        if section[quest.title] and not self:IsTracked(quest) then
            if Client.GetWatchCount() < Client.MAX_WATCHES then
                if Client.AddQuestWatch(quest.index) then
                    applied = applied + 1
                end
            end
        end
        index = index + 1
    end

    self.restored = true
    if applied > 0 then
        Client.RefreshQuestWatch()
        UQ:Debug("restored tracking on " .. applied .. " quest(s)")
    end
    return true
end

-- Keeps the remembered set aligned with what the client currently reports.
function Tracker:Sync()
    local state = State()
    if not state then
        return
    end
    -- A snapshot taken while a header is collapsed does not list every quest,
    -- so it must not drive removals from the remembered set.
    local trustRemovals = self.restored and state:IsComplete()

    local quests = state:GetOrderedQuests()
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        if self:IsTracked(quest) then
            self:Remember(quest.title)
        elseif trustRemovals and self:IsRemembered(quest.title) then
            self:Forget(quest.title)
        end
        index = index + 1
    end
end

function Tracker:GetTrackedTitles()
    local config = Config()
    local list = {}
    if not config then
        return list
    end
    local section = config:GetSection(SECTION)
    if not section then
        return list
    end
    for title in pairs(section) do
        table.insert(list, title)
    end
    return list
end

-- Lifecycle -----------------------------------------------------------------

function Tracker:OnEnable()
    local config = Config()
    if config and not config:Get("restoreTracking") then
        self.restored = true
    end

    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("tracker.restore", RESTORE_INTERVAL, function()
            if Tracker:Restore() then
                local d = UQ:GetModule("Driver")
                if d then
                    d:Unschedule("tracker.restore")
                end
            end
        end)
        driver:Schedule("tracker.sync", 1.0, function() Tracker:Sync() end)
    end

    local state = State()
    if state then
        state:AddListener(function(event)
            if event == "QUEST_LOG_CHANGED" then
                local d = UQ:GetModule("Driver")
                if d then
                    d:Wake("tracker.sync")
                end
            end
        end)
    end
end
