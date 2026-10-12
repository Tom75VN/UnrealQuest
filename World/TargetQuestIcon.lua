--[[
UnrealQuest / World/TargetQuestIcon.lua

Retail's quest shield on the target portrait, shown while the target is a
creature an unfinished quest objective still wants. The question "is it
wanted" is ObjectiveMatch's; where the icon may be drawn is
Client.GetTargetFramePortrait's (UnrealUI's own target frame only).
]]

local UQ = UnrealQuest
local Client = UQ.Client
local TargetQuestIcon = UQ:NewModule("TargetQuestIcon")

local POLL_INTERVAL = 0.2

TargetQuestIcon.holder = nil
TargetQuestIcon.shown = false
TargetQuestIcon.lastKey = nil

local function WantsUnit(unitKey)
    local matcher = UQ:GetModule("ObjectiveMatch")
    local results = matcher and matcher:FindForUnit(unitKey)
    if not results then
        return false
    end
    local index = 1
    local total = table.getn(results)
    while index <= total do
        if not results[index].finished then
            return true
        end
        index = index + 1
    end
    return false
end

function TargetQuestIcon:IsEnabled()
    local config = UQ:GetModule("Config")
    return not (config and config:Get("targetQuestIcon") == false)
end

function TargetQuestIcon:Wanted()
    if not self:IsEnabled() or not Client.UnitExists("target")
            or Client.UnitIsPlayer("target") then
        return false
    end
    local unitKey = UQ.NameKey(Client.GetUnitName("target"))
    self.lastKey = unitKey
    return unitKey ~= nil and WantsUnit(unitKey)
end

function TargetQuestIcon:Refresh()
    local portrait, frame
    if self:Wanted() then
        portrait, frame = Client.GetTargetFramePortrait()
    end
    if portrait then
        if not self.holder then
            self.holder = Client.CreateTargetQuestIcon()
        end
        self.shown = Client.ShowTargetQuestIcon(self.holder, portrait, frame)
        return
    end
    if self.shown then
        Client.HideTargetQuestIcon(self.holder)
        self.shown = false
    end
end

function TargetQuestIcon:GetStatus()
    return {
        enabled = self:IsEnabled(),
        host = Client.GetTargetFramePortrait() ~= nil,
        shown = self.shown,
        lastKey = self.lastKey,
    }
end

function TargetQuestIcon:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("world.targetquesticon", POLL_INTERVAL, function()
        TargetQuestIcon:Refresh()
    end)
    local events = UQ:GetModule("Events")
    if events then
        events:Register("PLAYER_TARGET_CHANGED", function()
            local d = UQ:GetModule("Driver")
            if d then
                d:Wake("world.targetquesticon")
            end
        end)
    end
end
