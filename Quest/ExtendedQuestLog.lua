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

The row count is not EQL3's fixed 27: the rows are spaced by the live row
height and only as many are installed as end inside the list page. That count
is also what QUESTS_DISPLAYED is set to, so everything past it is what the
client's own FauxScrollFrame scrolls -- exactly as the native log behaves.

STANDALONE ONLY.

unrealUI now carries this same extension itself (unrealUI/modules/
questlogextended.lua, with its own copy of the parchment art), on top of the
two-pane Quest Log its Modern and Modern WoW themes already draw. unrealUI
therefore owns the Quest Log under every one of its themes, and this module
applies nothing at all whenever unrealUI is installed -- not merely when a
non-native theme is active. Two addons re-anchoring the same native widgets is
the failure mode being avoided here, and unrealUI wins by design.

"Installed" means the UnrealUI global exists, which is also what
Client.GetUnrealUIQuestLogMode reads for the diagnostic note below. Resolution
is delayed until that global appears, or until the same fifteen-second
late-load grace period used by Core/Settings.lua expires, because addon load
order does not guarantee unrealUI has run when this module is enabled.
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

-- Which unrealUI surface owns the Quest Log. Diagnostic wording only; nothing
-- branches on it, because any unrealUI at all is enough to stand down.
function ExtendedQuestLog:DescribeHost()
    local mode = Client.GetUnrealUIQuestLogMode()
    if mode == "classic" then
        return "its Classic WoW theme's extended two-page Quest Log"
    elseif mode == "modern" then
        return "its Modern two-pane Quest Log"
    end
    return "its own Quest Log"
end

function ExtendedQuestLog:Resolve(force)
    if self.mode then
        return self.mode
    end

    if Client.HasObject("UnrealUI") then
        -- Installed is enough. An older unrealUI without the extension is
        -- still treated as owning this frame, so UnrealQuest never modifies a
        -- native widget it may skin later in the same load sequence.
        self.mode = "host"
        UQ:DeclareCapability("extendedClassicQuestLog", "detected",
            "unrealUI is installed and owns the Quest Log through "
            .. self:DescribeHost()
            .. "; UnrealQuest's EQL3 parchment extension is standalone-only and "
            .. "intentionally left the native frame unchanged")
        return self.mode
    end

    if not force then
        return nil
    end

    local applied = Client.ApplyExtendedClassicQuestLog()
    if applied == nil then
        -- The native frames are not available yet. Keep polling rather than
        -- making their load timing a correctness dependency.
        return nil
    end

    self.mode = "standalone"
    self.applied = applied and true or false
    if self.applied then
        self:StartRewardLayoutJob()
        local rows = Client.GetExtendedClassicQuestLogRows()
        UQ:DeclareCapability("extendedClassicQuestLog", "unverified",
            "no unrealUI in this session, so the native Quest Log was expanded to "
            .. tostring(rows or "?")
            .. " stock rows -- as many as the measured row height fits inside the left "
            .. "parchment page, so a longer quest list scrolls on the native FauxScrollFrame "
            .. "instead of running off the page -- with its stock detail pane on the EQL3 "
            .. "right page; the generic frame calls and row-template technique are supported, "
            .. "but the combined layout still needs one in-game visual confirmation")
    else
        UQ:DeclareCapability("extendedClassicQuestLog", "missing",
            "the standalone layout was selected, but one of the native Quest Log "
            .. "widgets or EQL3 parchment textures could not be prepared")
    end
    return self.mode
end

function ExtendedQuestLog:OnInit()
    UQ:DeclareCapability("extendedClassicQuestLog", "unverified",
        "waiting to determine whether unrealUI is installed and owns the Quest Log")
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
