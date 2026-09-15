--[[
UnrealQuest / Quest/QuestRewardColors.lua

Item rarity colour on the reward names of the quest-giver's completion window
("Complete Quest"). The stock panel draws every reward name in one flat colour,
so on the one window where the player has to choose between two rewards, a
green and a blue look the same.

The quality itself comes from the client, not from the bundled world data:
GetQuestItemInfo reports it for whatever the open window is offering, and
GetItemQualityColor turns the index into a colour. Both are DOCUMENTED and not
runtime-probed here, so the capability is declared "documented" and the whole
feature is written to leave the buttons untouched when either call is absent --
see the block above Client.SetQuestRewardItemQualityColors in
Compatibility/ClientAPI.lua for how a button is matched to a reward, and why
that is done by name rather than by index.

Polled on the shared driver, like Quest/QuestLogRewards.lua and for the same
reason: the native panel rewrites its own reward rows whenever it refreshes, so
a colour written once on an event would be handed back the next time the window
was opened. Turning the option off restores the colour each region carried
before this addon first touched it, without a reload.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestRewardColors = UQ:NewModule("QuestRewardColors")

local POLL_INTERVAL = 0.3

function QuestRewardColors:Refresh()
    local config = UQ:GetModule("Config")
    local enabled = true
    if config and config:Get("questRewardItemColors") == false then
        enabled = false
    end
    Client.SetQuestRewardItemQualityColors(enabled)
end

function QuestRewardColors:OnInit()
    UQ:DeclareCapability("questRewardItemColors", "documented",
        "GetQuestItemInfo is documented (category Quest) to return name, texture, "
        .. "numItems, quality and isUsable for the open quest-giver window, and "
        .. "GetItemQualityColor (category Item) to return r, g, b and a hex tag for a "
        .. "quality index; both are DOCUMENTED_NOT_RUNTIME_VERIFIED and neither has "
        .. "been probed on this client. The QuestRewardItem<N> buttons and their Name "
        .. "FontStrings are USER_CONFIRMED_INGAME in the frame inventory of behaviour "
        .. "test questgiver.addon_resolves_quest.v1, but are still resolved by name and "
        .. "skipped when absent. A button whose name string matches no reward the "
        .. "window reports keeps the colour it already had")
end

function QuestRewardColors:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("quest.rewardcolors", POLL_INTERVAL, function()
        QuestRewardColors:Refresh()
    end)
end
