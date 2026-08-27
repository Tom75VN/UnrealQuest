--[[
UnrealQuest / Quest/Tracker.lua

Unlimited addon-owned quest tracking, with a best-effort mirror into the
client's native watch list.

Client facts this is built on, all from measured or in-game confirmed evidence:

  * AddQuestWatch, RemoveQuestWatch and IsQuestWatched share one index space:
    the raw GetQuestLogTitle index, headers included. They round-trip cleanly.
  * The watch list is client state that does NOT survive a UI reload here.
    After /reload the client reports zero watched quests even for a quest the
    player was tracking. Persisting and reapplying the set is the addon's job.
  * The client caps the watch list at five quests. That list is therefore a
    mirror only: the saved addon set is authoritative and has no five-quest
    ceiling. When a native slot opens, another addon-tracked quest is promoted
    into it.

Two ordering hazards are handled explicitly, because getting either wrong
produces a bug that looks exactly like "the client does not persist tracking":

  1. The quest log may not be populated when the addon enables, so restoration
     retries on the driver instead of running once.
  2. The first sync pass can run before restoration finishes. Native watches
     are imported immediately, but native removals are not trusted until the
     remembered set has been restored, so an early sync can never erase it.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Tracker = UQ:NewModule("Tracker")

local SECTION = "trackedQuests"
-- Same config section Quest/TrackerFrame.lua's BuildLines filters the window
-- by (HIDDEN_QUESTS there). By explicit request, untracking a quest through
-- any surface -- the quest log's Untrack button, shift-click on the tracker
-- window, or /uq untrack -- also removes it from the tracker window, and
-- tracking it again brings it back; they are no longer two separate
-- gestures. Both this section's name and the fold-membership scheme
-- ("key present" means hidden) are duplicated rather than shared as a
-- cross-module call, since the two modules otherwise stay independent
-- (Quest/TrackerFrame.lua owns the window, this module owns the watch list).
local HIDDEN_SECTION = "trackerHiddenQuests"
local COLLAPSED_QUESTS_SECTION = "trackerCollapsedQuests"
local COLLAPSED_ZONES_SECTION = "trackerCollapsedZones"
local RESTORE_INTERVAL = 1.0
local RESTORE_ATTEMPTS = 20

Tracker.restored = false
Tracker.attempts = 0
Tracker.nativeTitles = nil

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

function Tracker:Forget(title, force)
    local config = Config()
    if not config then
        return
    end
    -- Never forget before restoration has completed: an early sync pass would
    -- otherwise wipe exactly the set it is meant to restore.
    if not self.restored and not force then
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

-- Redraws the client's native tracked-objectives panel after a watch-list
-- change, then puts it straight back where the player's setting says it
-- belongs.
--
-- Both halves are load-bearing, and both rest on the same measured record
-- (knowledge.json / questwatch.public_refresh_after_watch_change,
-- BEHAVIOR_VERIFIED, USER_CONFIRMED_INGAME):
--
--   * AddQuestWatch alone changes the watch state but leaves QuestWatchFrame
--     stale, so the public QuestWatch_Update helper has to be called for the
--     native panel to be correct at all.
--   * That same call "immediately shows the native tracked-objectives panel"
--     -- which is the bug this function exists to close. A player who asked
--     for the native panel to stay hidden (trackerHideNativeWatch) got it
--     flashed back on screen by every single track/untrack, and it stayed
--     until the 2-second re-hide job came round.
--
-- The re-hide is a plain frame Hide through Client.SetNativeQuestWatchShown.
-- It is emphatically NOT a call into QuestWatchFrame's own OnEvent handler:
-- that is a recorded failed approach on this client, "confirmed separately to
-- crash the client uncatchably" in the same record, and a standing rule of
-- this project.
-- Nothing here touches a native handler, only the frame's own Show/Hide.
local function RefreshNativeWatch()
    Client.RefreshQuestWatch()
    local trackerFrame = UQ:GetModule("TrackerFrame")
    if trackerFrame then
        trackerFrame:ApplyNativeWatchVisibility()
    end
end

-- Live tracking state -------------------------------------------------------

-- The saved set is the tracking state UnrealQuest exposes to every surface.
-- IsQuestWatched cannot be authoritative because the client can represent at
-- most five entries; using it here is what made the sixth Track click fail.

function Tracker:IsTracked(quest)
    if not quest or not quest.title then
        return false
    end
    return self:IsRemembered(quest.title)
end

local function SetHidden(title, hidden)
    local config = Config()
    if not config or not title then
        return
    end
    config:SetSectionEntry(HIDDEN_SECTION, title, hidden and 1 or nil)
end

-- A successful Track click must make the quest visible in the custom window,
-- not merely change its saved stripe state. Clear folds that can conceal this
-- particular quest, then let TrackerFrame grow through the revealed quest.
local function RevealTrackedQuest(quest)
    local config = Config()
    if config then
        config:SetSectionEntry(COLLAPSED_QUESTS_SECTION, quest.title, nil)
        if type(quest.zone) == "string" and quest.zone ~= "" then
            config:SetSectionEntry(COLLAPSED_ZONES_SECTION, quest.zone, nil)
        end
    end
    local trackerFrame = UQ:GetModule("TrackerFrame")
    if trackerFrame then
        trackerFrame:RevealQuest(quest)
    end
end

local function SnapshotNative(quests)
    local titles = {}
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        if quest and quest.index and quest.title and Client.IsQuestWatched(quest.index) then
            titles[quest.title] = 1
        end
        index = index + 1
    end
    return titles
end

-- Drops a native watch the native panel cannot render.
--
-- See Client.CanNativeWatchQuest: QuestWatch_Update concatenates the objective
-- text it reads with the two-argument GetQuestLogLeaderBoard without a nil
-- check, and it does so from QuestLog_OnEvent, where no pcall of ours can
-- catch the error. A watch already placed on such a quest -- by an earlier
-- session of this addon, or by the player through the native Quest Log -- is
-- therefore removed again before the next QUEST_LOG_UPDATE turns it into an
-- uncatchable error.
--
-- The title stays remembered, because UnrealQuest's own tracker window reads
-- objectives through the compatibility layer's fallback path and renders the
-- quest fine. It is dropped from the native snapshot as well, so that Sync
-- does not read this removal as the player untracking the quest.
local function PurgeUnreadableNativeWatches(self, quests)
    local removed = 0
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        if quest and quest.index and quest.title
            and Client.IsQuestWatched(quest.index)
            and not Client.CanNativeWatchQuest(quest.index) then
            Client.RemoveQuestWatch(quest.index)
            if self.nativeTitles then
                self.nativeTitles[quest.title] = nil
            end
            removed = removed + 1
            UQ:Debug("dropped the native watch on \"" .. quest.title
                .. "\": the native panel cannot read its objectives")
        end
        index = index + 1
    end
    return removed
end

-- Fill only the native slots the client actually has. AddQuestWatch returns
-- no useful success value, so every attempted addition is verified through
-- IsQuestWatched before it counts as a changed native watch.
function Tracker:MirrorNativeWatches(quests)
    local count = Client.GetWatchCount()
    if count >= Client.MAX_WATCHES then
        return 0
    end

    local applied = 0
    local index = 1
    local total = table.getn(quests)
    while index <= total and count < Client.MAX_WATCHES do
        local quest = quests[index]
        if quest and quest.index and self:IsTracked(quest)
            and not Client.IsQuestWatched(quest.index)
            and Client.CanNativeWatchQuest(quest.index) then
            Client.AddQuestWatch(quest.index)
            if Client.IsQuestWatched(quest.index) then
                applied = applied + 1
                count = count + 1
            end
        end
        index = index + 1
    end
    return applied
end

function Tracker:Track(quest)
    if not quest or not quest.index or not quest.title then
        return false
    end
    self:Remember(quest.title)
    SetHidden(quest.title, false)

    local nativeChanged = false
    if not Client.IsQuestWatched(quest.index)
        and Client.GetWatchCount() < Client.MAX_WATCHES
        and Client.CanNativeWatchQuest(quest.index) then
        Client.AddQuestWatch(quest.index)
        nativeChanged = Client.IsQuestWatched(quest.index) and true or false
    end
    if nativeChanged then
        self.nativeTitles = self.nativeTitles or {}
        self.nativeTitles[quest.title] = 1
        RefreshNativeWatch()
    end
    RevealTrackedQuest(quest)
    return true
end

function Tracker:Untrack(quest)
    if not quest or not quest.index or not quest.title then
        return false
    end
    self:Forget(quest.title, true)
    SetHidden(quest.title, true)

    local nativeChanged = false
    if Client.IsQuestWatched(quest.index) then
        Client.RemoveQuestWatch(quest.index)
        nativeChanged = not Client.IsQuestWatched(quest.index)
    end
    if self.nativeTitles then
        self.nativeTitles[quest.title] = nil
    end

    local state = State()
    if state then
        local applied = self:MirrorNativeWatches(state:GetOrderedQuests())
        if applied > 0 then
            nativeChanged = true
        end
        self.nativeTitles = SnapshotNative(state:GetOrderedQuests())
    end
    if nativeChanged then
        RefreshNativeWatch()
    end
    return true
end

-- The event-driven half of the purge above. Tracker:Sync polls once a second,
-- which is fast enough to keep the addon's own state honest but not fast
-- enough here: the native panel redraws on the very next QUEST_LOG_UPDATE, so
-- a watch the player just placed through the native Quest Log's own Track
-- button -- the one tracking path this addon does not own -- has to be checked
-- the moment the client says the quest log or the watch list changed.
function Tracker:PurgeNativeWatches()
    local state = State()
    if not state then
        return 0
    end
    local removed = PurgeUnreadableNativeWatches(self, state:GetOrderedQuests())
    if removed > 0 then
        RefreshNativeWatch()
    end
    return removed
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
    local purged = PurgeUnreadableNativeWatches(self, quests)
    local applied = self:MirrorNativeWatches(quests)

    self.restored = true
    self.nativeTitles = SnapshotNative(quests)
    if purged > 0 then
        RefreshNativeWatch()
    end
    if applied > 0 then
        RefreshNativeWatch()
        UQ:Debug("restored tracking on " .. applied .. " quest(s)")
    end
    return true
end

-- Imports native watch changes without letting the five-slot mirror erase
-- addon-tracked overflow. A transition from watched to unwatched is trusted
-- only when that title was in the previous native snapshot; a title that has
-- never fit in the native list is therefore preserved.
function Tracker:Sync()
    local state = State()
    if not state then
        return
    end
    -- A snapshot taken while a header is collapsed does not list every quest,
    -- so it must not drive removals from the remembered set.
    local trustRemovals = self.restored and state:IsComplete()

    local quests = state:GetOrderedQuests()
    local purged = PurgeUnreadableNativeWatches(self, quests)
    local native = SnapshotNative(quests)

    if trustRemovals and self.nativeTitles then
        for title in pairs(self.nativeTitles) do
            if not native[title] and state:GetQuestByTitle(title) then
                self:Forget(title, true)
                SetHidden(title, true)
            end
        end
    end

    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        if native[quest.title] then
            self:Remember(quest.title)
            SetHidden(quest.title, false)
        end
        index = index + 1
    end

    -- A complete model is also the safe moment to remove stale saved titles
    -- for quests no longer in the log, including overflow quests that never
    -- occupied a native slot.
    if trustRemovals then
        local config = Config()
        local section = config and config:GetSection(SECTION)
        if section then
            local stale = {}
            for title in pairs(section) do
                if not state:GetQuestByTitle(title) then
                    table.insert(stale, title)
                end
            end
            index = 1
            total = table.getn(stale)
            while index <= total do
                self:Forget(stale[index], true)
                SetHidden(stale[index], false)
                index = index + 1
            end
        end
    end

    self.nativeTitles = native
    if self.restored then
        local applied = self:MirrorNativeWatches(quests)
        if applied > 0 then
            self.nativeTitles = SnapshotNative(quests)
        end
        if applied > 0 or purged > 0 then
            RefreshNativeWatch()
        end
    elseif purged > 0 then
        RefreshNativeWatch()
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

    local events = UQ:GetModule("Events")
    if events then
        local purge = function()
            Tracker:PurgeNativeWatches()
        end
        events:Register("QUEST_LOG_UPDATE", purge)
        events:Register("QUEST_WATCH_UPDATE", purge)
        events:Register("UNIT_QUEST_LOG_CHANGED", purge)
    end

    local state = State()
    if state then
        state:AddListener(function(event, quest)
            -- QuestState's first scan runs before this module enables, so the
            -- current login snapshot is not auto-tracked. Route later quest
            -- additions through the ordinary path so the unlimited saved set,
            -- native five-slot mirror and custom tracker window stay aligned.
            if event == "QUEST_ADDED" and quest then
                Tracker:Track(quest)
            elseif event == "QUEST_LOG_CHANGED" then
                local d = UQ:GetModule("Driver")
                if d then
                    d:Wake("tracker.sync")
                end
            end
        end)
    end
end
