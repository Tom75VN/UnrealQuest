--[[
UnrealQuest / Quest/QuestLogTranslation.lua

Translated presentation for the native Quest Log detail pane. The bundled
quest locale rows contain exactly three player-facing fields: T (title), O
(objective summary) and D (description). Those are the only fields this layer
touches. QuestLogObjective1..10 stay native because they carry live progress
counters and completion state that static database text cannot authoritatively
replace.

The live quest row remains the identity source. A selected quest must already
have an unambiguous numeric questId in QuestState, the requested locale table
must contain that exact row, and Database:GetQuestDisplayText must be able to
expand every quest-text token. Any failure leaves the whole field native.

Stock QuestLog_Update owns these FontStrings and may rewrite them on selection,
scroll or quest progress. A small polling pass therefore reapplies only changed
display strings. When the setting, language or selection changes, the public
native refresh helper first restores the stock pane; this prevents a missing
translation from inheriting stale text from the previously selected quest.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestLogTranslation = UQ:NewModule("QuestLogTranslation")

local PARENT_NAME = "QuestLogFrame"
local SCROLL_NAME = "QuestLogDetailScrollFrame"
local POLL_INTERVAL = 0.2

local FIELDS = {
    { name = "QuestLogQuestTitle", field = "T" },
    { name = "QuestLogObjectivesText", field = "O" },
    { name = "QuestLogQuestDescription", field = "D" },
}

QuestLogTranslation.appliedSignature = nil
QuestLogTranslation.translatedFields = 0

local function TranslationEnabled()
    local config = UQ:GetModule("Config")
    return not config or config:Get("translateQuestTitles") ~= false
end

local function SelectedQuest()
    local selection = Client.GetQuestLogSelection()
    if not selection then
        return nil, nil
    end
    local title, _, _, isHeader = Client.GetQuestLogEntry(selection)
    if not title or isHeader then
        return nil, selection
    end
    local state = UQ:GetModule("QuestState")
    local quest = state and state:GetQuestByTitle(title)
    if not quest or type(quest.questId) ~= "number" then
        return nil, selection
    end
    return quest, selection
end

local function RestoreNative()
    if QuestLogTranslation.appliedSignature then
        if not Client.RefreshQuestLog() then
            -- Keep the signature so the next poll retries. Clearing it after
            -- a failed refresh would make stale translated text look native.
            return false
        end
    end
    QuestLogTranslation.appliedSignature = nil
    QuestLogTranslation.translatedFields = 0

    -- QuestLog_Update restores more than the detail pane: it also rewrites
    -- every visible QuestLogTitle row in the client's language. Reapply the
    -- row presentation in this same call so changing the selected quest never
    -- exposes those native titles until the independent 0.2s row poll runs.
    local levels = UQ:GetModule("QuestLogLevels")
    if levels then
        levels:Refresh()
    end
    return true
end

function QuestLogTranslation:Refresh()
    local frame = Client.GetNamedObject(PARENT_NAME)
    if not frame or not Client.IsObjectShown(frame) then
        return
    end
    if not TranslationEnabled() then
        RestoreNative()
        return
    end

    local database = UQ:GetModule("Database")
    local quest, selection = SelectedQuest()
    local language = UQ.GetLanguage and UQ.GetLanguage()
    local clientLanguage = Client.GetLocale()
    if not database or not quest or type(language) ~= "string"
        or language == clientLanguage
        or not database:GetQuestTextForLanguage(quest.questId, language) then
        RestoreNative()
        return
    end

    local signature = tostring(selection) .. ":" .. tostring(quest.questId)
        .. ":" .. language
    if self.appliedSignature and self.appliedSignature ~= signature then
        if not RestoreNative() then
            return
        end
        -- QuestLog_Update can rebuild selection-owned state. Resolve again
        -- before touching any field rather than assuming the same row survived.
        quest, selection = SelectedQuest()
        if not quest or type(quest.questId) ~= "number" then
            return
        end
        signature = tostring(selection) .. ":" .. tostring(quest.questId)
            .. ":" .. language
    end

    local translated = 0
    local index = 1
    local total = table.getn(FIELDS)
    while index <= total do
        local spec = FIELDS[index]
        local object = Client.GetNamedObject(spec.name)
        if object then
            local nativeText = Client.GetObjectText(object)
            local displayText = database:GetQuestDisplayText(
                quest, spec.field, nativeText)
            if type(displayText) == "string" and displayText ~= ""
                and displayText ~= nativeText
                and Client.SetNativeObjectText(object, displayText) then
                translated = translated + 1
            elseif self.appliedSignature == signature
                and type(displayText) == "string" and displayText ~= ""
                and displayText == nativeText then
                -- The desired translation survived the stock refresh.
                translated = translated + 1
            end
        end
        index = index + 1
    end

    if translated > 0 then
        self.appliedSignature = signature
        self.translatedFields = translated
        Client.UpdateScrollChildRect(Client.GetNamedObject(SCROLL_NAME))
    else
        self.appliedSignature = nil
        self.translatedFields = 0
    end
end

function QuestLogTranslation:OnInit()
    UQ:DeclareCapability("questLogTranslation", "detected",
        "/urp interface QuestLogFrame (BEHAVIOR_VERIFIED, capturedAt 2026-08-23) confirms "
        .. "QuestLogQuestTitle, QuestLogObjectivesText and QuestLogQuestDescription; "
        .. "only those static T/O/D presentation fields are translated")
end

function QuestLogTranslation:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("questlog.translation", POLL_INTERVAL, function()
        QuestLogTranslation:Refresh()
    end)
end
