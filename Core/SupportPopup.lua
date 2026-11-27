--[[
UnrealQuest / Core/SupportPopup.lua

A one-time reminder, a few seconds after entering the world, asking the player
to like the addon in the launcher. Two answers: "I already liked it" stops it
for good (`supportPopupDismissed`, account-wide); "OK, I will add a like" only
closes it until the next login. Built by Client.CreateSupportPopup.

A dismissed popup schedules no job and creates no frame.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local SupportPopup = UQ:NewModule("SupportPopup")

local SHOW_DELAY = 6
local JOB = "support.popup"
local DISMISSED_KEY = "supportPopupDismissed"
local THANKS_GAP = 6

SupportPopup.frame = nil
SupportPopup.shown = false

local function Config()
    return UQ:GetModule("Config")
end

function SupportPopup:IsDismissed()
    local config = Config()
    return config and config:Get(DISMISSED_KEY) == true
end

local function SetDismissed()
    local config = Config()
    if config then
        config:Set(DISMISSED_KEY, true)
    end
end

function SupportPopup:Show()
    if not self.frame then
        self.frame = Client.CreateSupportPopup("UnrealQuestSupportPopup", {
            title = UQ.L("SUPPORT_POPUP_TITLE"),
            lines = {
                { UQ.L("SUPPORT_POPUP_QUESTION"), 0 },
                { UQ.L("SUPPORT_POPUP_MESSAGE"), 0 },
                { UQ.L("SUPPORT_POPUP_THANKS"), THANKS_GAP },
            },
            leftText = UQ.L("SUPPORT_POPUP_ALREADY_LIKED"),
            rightText = UQ.L("SUPPORT_POPUP_WILL_LIKE"),
            onLeft = SetDismissed,
        })
    end
    self.shown = Client.ShowSupportPopup(self.frame)
    return self.shown
end

function SupportPopup:OnEnable()
    if self:IsDismissed() then
        return
    end
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    -- One shot: the first fire, SHOW_DELAY after entering the world, stops
    -- the job before showing anything.
    driver:Schedule(JOB, SHOW_DELAY, function()
        local d = UQ:GetModule("Driver")
        if d then
            d:Unschedule(JOB)
        end
        if not SupportPopup:IsDismissed() then
            SupportPopup:Show()
        end
    end)
end
