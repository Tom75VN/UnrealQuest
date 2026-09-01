--[[
UnrealQuest / Quest/ExtendedQuestLog.lua

Two-page native quest log, adapted from the layout and artwork supplied with
Extended QuestLog 3.6.1 (Copyright 2006 Daniel Rehn).

This module deliberately imports only the presentation that UnrealQuest needs:
the stock quest list is expanded down the left page and the stock detail pane
is moved onto a second parchment page. The client still owns selection,
scrolling, quest actions and detail population, while UnrealQuest's existing
level, translation, tracking and action-button modules continue to decorate
those same native widgets.

unrealUI's Modern and Modern WoW themes already replace the Quest Log with a
two-pane surface of their own. Theme resolution is therefore delayed until
unrealUI has published its active style, or until the same fifteen-second
late-load grace period used by Core/Settings.lua expires. The extension is
installed only for a standalone UnrealQuest session or unrealUI's Classic WoW
theme, which intentionally retains native client chrome.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local ExtendedQuestLog = UQ:NewModule("ExtendedQuestLog")

local HOST_POLL_INTERVAL = 0.5
local HOST_POLL_SECONDS = 15
local REWARD_LAYOUT_INTERVAL = 0.2

ExtendedQuestLog.mode = nil
ExtendedQuestLog.waited = 0
ExtendedQuestLog.applied = false
ExtendedQuestLog.rewardJobStarted = false

function ExtendedQuestLog:StartRewardLayoutJob()
    if self.rewardJobStarted or not self.applied then
        return
    end
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    self.rewardJobStarted = true
    driver:Schedule("questlog.extended.rewards", REWARD_LAYOUT_INTERVAL,
        function()
            if Client.IsExtendedClassicQuestLogShown() then
                Client.RefreshExtendedClassicQuestLogRewards()
            end
        end)
end

function ExtendedQuestLog:Resolve(force)
    if self.mode then
        return self.mode
    end

    local mode = Client.GetUnrealUIQuestLogMode()
    if not mode and force then
        if Client.HasObject("UnrealUI") then
            -- A present but incomplete/older unrealUI is treated as owning the
            -- Quest Log. This avoids modifying a native frame that it may skin
            -- later in the same load sequence.
            mode = "modern"
        else
            mode = "standalone"
        end
    end
    if not mode then
        return nil
    end

    if mode == "modern" then
        self.mode = mode
        UQ:DeclareCapability("extendedClassicQuestLog", "detected",
            "unrealUI is using a non-native theme and owns its two-pane Quest Log; "
            .. "the EQL3 parchment extension intentionally left the native frame unchanged")
        return mode
    end

    local applied = Client.ApplyExtendedClassicQuestLog()
    if applied == nil then
        -- The native frames are not available yet. Keep polling rather than
        -- making their load timing a correctness dependency.
        return nil
    end

    self.mode = mode
    self.applied = applied and true or false
    if self.applied then
        self:StartRewardLayoutJob()
        UQ:DeclareCapability("extendedClassicQuestLog", "unverified",
            "the native Quest Log was expanded to 27 stock rows on a left parchment page "
            .. "with its stock detail pane on the EQL3 right page; the generic frame calls "
            .. "and row-template technique are supported, but the combined layout still needs "
            .. "one in-game visual confirmation")
    else
        UQ:DeclareCapability("extendedClassicQuestLog", "missing",
            "the standalone/Classic WoW layout was selected, but one of the native Quest Log "
            .. "widgets or EQL3 parchment textures could not be prepared")
    end
    return mode
end

function ExtendedQuestLog:OnInit()
    UQ:DeclareCapability("extendedClassicQuestLog", "unverified",
        "waiting to determine whether unrealUI owns the Quest Log or retains native Classic WoW chrome")
end

function ExtendedQuestLog:OnEnable()
    if self:Resolve(false) then
        return
    end

    local driver = UQ:GetModule("Driver")
    if not driver then
        self:Resolve(true)
        return
    end

    driver:Schedule("questlog.extended", HOST_POLL_INTERVAL, function(elapsed)
        ExtendedQuestLog.waited = ExtendedQuestLog.waited
            + (elapsed or HOST_POLL_INTERVAL)
        local mode = ExtendedQuestLog:Resolve(
            ExtendedQuestLog.waited >= HOST_POLL_SECONDS)
        if mode then
            local running = UQ:GetModule("Driver")
            if running then
                running:Unschedule("questlog.extended")
            end
        end
    end)
end
