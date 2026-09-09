--[[
UnrealQuest / Quest/QuestLogRewards.lua

Experience and reputation rows at the tail of a quest's reward section, on all
three surfaces that state a quest's rewards: the Quest Log, the quest-giver's
offer window ("Accept"), and its completion window ("Complete Quest").

The client's own Quest surface reports the item and money rewards and nothing
else -- there is no call anywhere in the compatibility database that returns a
quest's experience or its reputation deltas. Both therefore come from the
bundled world data (Database/quests.lua carries "xp" and a flat "rep" list;
see docs/WORLD-DATA-NOTES.md), which has two consequences worth stating:

  1. The quest has to be MATCHED first, by title, exactly like every other
     database-backed presentation in this addon. An unmatched or ambiguous row
     shows no reward rows at all rather than a guess, and a server-edited quest
     is expected to be one of those.
  2. The experience shown is the quest's recorded base value, not a prediction
     of what this character is granted -- the client scales the award by level
     and the data cannot know that. It is the quest's listed reward.

Reputation values may be negative: quest 1 rewards +75 with one faction and
-500 with another, so the sign is always drawn and losses are tinted red.

## Faction names

Reputation is recorded as a faction ID, and nothing available here can name it.
The client's whole Faction surface is indexed off the player's own reputation
pane (GetFactionInfo(index) walks the factions THAT character has met and never
reports an id), and no faction table ships in Database/. Database:GetFactionName
reads an optional Database/factions.lua when one is present; until it is, the
row renders the amount alone rather than inventing a label. That is deliberate:
a wrong faction name is worse than no faction name.

## Two ways in, because the giver panels have no quest log row

The Quest Log resolves through the addon's own quest model, by the selected
row's title. The giver panels cannot: an OFFERED quest is not in the log yet,
so there is no row and no index. Their title comes from Client.GetQuestGiverTitle
(GetTitleText -- documented as the title of the last quest-giver packet,
detail/progress/complete alike) and is matched straight against the database's
title index. That match is accepted ONLY when exactly one quest carries the
title: two quests sharing a name is an ambiguity this surface has no second
signal to break, so it shows nothing rather than the wrong quest's numbers.

## Placement

Client.SetQuestRewardSummary owns it -- the rows are anchored below the last
shown member of the stock reward chain, re-placed on every poll because the
native detail refresh rewrites that chain on every selection. See the note
above it in Compatibility/ClientAPI.lua.

Polled on the shared driver, like Quest/QuestLogButtons.lua and for the same
reason: this client has no quest-log-selection-changed event this addon trusts.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestLogRewards = UQ:NewModule("QuestLogRewards")

local POLL_INTERVAL = 0.3
local LOG_FRAME_NAME = "QuestLogFrame"
local GIVER_SURFACES = { "detail", "complete" }

-- The stock "you gain" gold and a muted red for a reputation loss.
local XP_COLOR = { r = 1.00, g = 0.82, b = 0.00 }
local REP_GAIN_COLOR = { r = 0.60, g = 0.85, b = 0.60 }
local REP_LOSS_COLOR = { r = 0.90, g = 0.40, b = 0.40 }

local function Config()
    return UQ:GetModule("Config")
end

local function Database()
    return UQ:GetModule("Database")
end

local function QuestState()
    return UQ:GetModule("QuestState")
end

-- Neither quest log surface hands over a quest id; the selected row's title is
-- the only stable join, exactly as Quest/QuestLogButtons.lua resolves it.
local function ResolveSelectedQuestId()
    local index = Client.GetQuestLogSelection()
    if not index then
        return nil
    end
    local title, _, _, isHeader = Client.GetQuestLogEntry(index)
    if not title or isHeader then
        return nil
    end
    local questState = QuestState()
    local quest = questState and questState:GetQuestByTitle(title)
    if not quest then
        return nil
    end
    return quest.questId
end

-- The offered/completed quest, by title alone. Only an unambiguous hit counts.
local function ResolveGiverQuestId(database)
    local title = Client.GetQuestGiverTitle()
    if not title then
        return nil
    end
    local key = UQ.NameKey(title)
    local ids = key and database:FindQuestIdsByTitleKey(key)
    if type(ids) ~= "table" or table.getn(ids) ~= 1 then
        return nil
    end
    return ids[1]
end

local function AddExperienceLine(lines, database, questId)
    local xp = database:GetQuestRewardXP(questId)
    if not xp then
        return
    end
    table.insert(lines, {
        text = UQ.L("QUESTLOG_REWARD_XP", tostring(xp)),
        r = XP_COLOR.r, g = XP_COLOR.g, b = XP_COLOR.b,
    })
end

local function AddReputationLines(lines, database, questId)
    local rewards = database:GetQuestRewardReputation(questId)
    if not rewards then
        return
    end
    local index = 1
    local count = table.getn(rewards)
    while index <= count do
        local reward = rewards[index]
        local amount = reward.value
        local signed = amount > 0 and ("+" .. tostring(amount)) or tostring(amount)
        local name = database:GetFactionName(reward.faction)
        local text
        if name then
            text = UQ.L("QUESTLOG_REWARD_REPUTATION", name, signed)
        else
            -- No faction table on this install; the amount stands alone rather
            -- than being labelled with an id the player cannot read.
            text = UQ.L("QUESTLOG_REWARD_REPUTATION_UNNAMED", signed)
        end
        local color = amount > 0 and REP_GAIN_COLOR or REP_LOSS_COLOR
        table.insert(lines, { text = text, r = color.r, g = color.g, b = color.b })
        index = index + 1
    end
end

-- nil when the quest is unmatched, or matched but records no reward.
local function BuildLines(database, questId)
    if not database or not questId then
        return nil
    end
    local lines = {}
    AddExperienceLine(lines, database, questId)
    AddReputationLines(lines, database, questId)
    if table.getn(lines) == 0 then
        return nil
    end
    return lines
end

local function ClearAll()
    Client.SetQuestRewardSummary("log", nil)
    local index = 1
    while index <= table.getn(GIVER_SURFACES) do
        Client.SetQuestRewardSummary(GIVER_SURFACES[index], nil)
        index = index + 1
    end
end

function QuestLogRewards:Refresh()
    local config = Config()
    if config and config:Get("questLogRewards") == false then
        ClearAll()
        return
    end
    local database = Database()
    if not database then
        ClearAll()
        return
    end

    -- Quest log: only while its window is up, and only for the selected row.
    local logFrame = Client.GetNamedObject(LOG_FRAME_NAME)
    local logLines = nil
    if logFrame and Client.IsObjectShown(logFrame) then
        logLines = BuildLines(database, ResolveSelectedQuestId())
    end
    Client.SetQuestRewardSummary("log", logLines)

    -- Offer and completion windows. Both are asked on every pass and the one
    -- that is not on screen clears itself inside SetQuestRewardSummary, so a
    -- swap between them cannot leave the other holding a stale line.
    local giverLines = BuildLines(database, ResolveGiverQuestId(database))
    local index = 1
    while index <= table.getn(GIVER_SURFACES) do
        Client.SetQuestRewardSummary(GIVER_SURFACES[index], giverLines)
        index = index + 1
    end
end

function QuestLogRewards:OnInit()
    local database = Database()
    local hasData = database and database:GetQuestRewardXP(1) ~= nil
    if hasData then
        UQ:DeclareCapability("questLogRewards", "detected",
            "Database/quests.lua carries the xp and rep reward fields; the client itself "
            .. "exposes no quest experience or reputation call in the compatibility database, "
            .. "so both values are read from the bundled world data after a title match. "
            .. "Quest Log placement rests on the same BEHAVIOR_VERIFIED QuestLogFrame walk the "
            .. "other quest log modules use. The giver offer/completion panels rest on "
            .. "quest_dialog.detail_reward_text_globals (USER_CONFIRMED_INGAME, 2026-08-20) "
            .. "for their Detail/Reward-prefixed heading names, plus GetTitleText, "
            .. "GetNumQuestChoices and GetNumQuestRewards, all three DOCUMENTED and NOT "
            .. "runtime-probed; their item and money frame names are resolved by name and "
            .. "fall through when absent")
    else
        UQ:DeclareCapability("questLogRewards", "missing",
            "Database/quests.lua on this install has no xp/rep reward fields; the reward "
            .. "rows stay hidden until the bundled data is synced with them")
    end
end

function QuestLogRewards:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("questlog.rewards", POLL_INTERVAL, function()
        QuestLogRewards:Refresh()
    end)
end
