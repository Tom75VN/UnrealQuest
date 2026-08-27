--[[
UnrealQuest / Quest/QuestLogTracking.lua

Unlimited tracking on the native quest-log rows. The client still owns only
five real watch slots; this layer chains Shift-click into Tracker's saved set
and renders that set independently on every visible row.

Standalone owns a fixed accent Frame on each row. The native
QuestLogTitleNCheck texture cannot be reused: the client reanchors it from the
title width after refreshes. When unrealUI has built its quest-log skin,
Client.SetQuestLogTrackMark detects and drives the row's existing uuiTrackMark
accent instead. No unrealUI load-order or API dependency is introduced.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestLogTracking = UQ:NewModule("QuestLogTracking")

local MAX_LOG_ROWS = 30
local CHAIN_MARKER = "unrealQuestUnlimitedTrackingChained"

QuestLogTracking.chainedRows = 0
QuestLogTracking.shiftClicks = 0
QuestLogTracking.standaloneMarks = 0
QuestLogTracking.unrealUIMarks = 0

local function State()
    return UQ:GetModule("QuestState")
end

local function Tracker()
    return UQ:GetModule("Tracker")
end

local function KeyIsSuffix(textKey, titleKey)
    if not textKey or not titleKey then
        return false
    end
    local textLength = string.len(textKey)
    local titleLength = string.len(titleKey)
    if titleLength > textLength then
        return false
    end
    return string.sub(textKey, textLength - titleLength + 1) == titleKey
end

local function QuestFromText(row)
    local text = Client.GetObjectText(row)
    local key = text and UQ.NameKey(text)
    local state = State()
    if not key or not state then
        return nil
    end

    local quests = state:GetOrderedQuests()
    local best, bestLength = nil, 0
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        local titleKey = quest and quest.titleKey
        local displayKey = quest and UQ.NameKey(UQ.GetQuestDisplayTitle(quest))
        local matchedKey = nil
        if KeyIsSuffix(key, titleKey) then
            matchedKey = titleKey
        end
        if KeyIsSuffix(key, displayKey)
            and (not matchedKey or string.len(displayKey) > string.len(matchedKey)) then
            matchedKey = displayKey
        end
        if matchedKey and string.len(matchedKey) > bestLength then
            best = quest
            bestLength = string.len(matchedKey)
        end
        index = index + 1
    end
    return best
end

local function QuestFromRow(row)
    local state = State()
    if not state then
        return nil
    end
    local questIndex = Client.GetFrameId(row)
    if questIndex then
        local title, _, _, isHeader = Client.GetQuestLogEntry(questIndex)
        if title and not isHeader then
            local quest = state:GetQuest(UQ.NameKey(title))
            if quest then
                return quest
            end
        end
    end
    return QuestFromText(row)
end

function QuestLogTracking:InstallRow(rowIndex)
    local row = Client.GetNamedObject("QuestLogTitle" .. tostring(rowIndex))
    if not row then
        return false, "missing"
    end
    if Client.IsScriptChained(row, CHAIN_MARKER) then
        return true, "already"
    end
    local installed = Client.ChainScript(row, "OnClick", function()
        if Client.IsShiftKeyDown() then
            local quest = QuestFromRow(row)
            local tracker = Tracker()
            if quest and tracker then
                QuestLogTracking.shiftClicks = QuestLogTracking.shiftClicks + 1
                tracker:Toggle(quest)
            end
        end

        -- The native handler runs first and rewrites both the row text and the
        -- stock Check texture. Reapply both addon-owned presentations in this
        -- same click, rather than leaving a 0.2-second flash of bare titles or
        -- the displaced native check for the poll to clean up.
        local levels = UQ:GetModule("QuestLogLevels")
        if levels then
            levels:Refresh()
        end
        QuestLogTracking:RefreshMarks()
    end)
    if not installed then
        return false, "chainFailed"
    end
    Client.MarkScriptChained(row, CHAIN_MARKER)
    self.chainedRows = self.chainedRows + 1
    return true, "installed"
end

function QuestLogTracking:InstallRows()
    local rowIndex = 1
    local misses = 0
    while rowIndex <= MAX_LOG_ROWS and misses < 3 do
        local ok, reason = self:InstallRow(rowIndex)
        if not ok and reason == "missing" then
            misses = misses + 1
        else
            misses = 0
        end
        rowIndex = rowIndex + 1
    end
end

function QuestLogTracking:RefreshMarks()
    local log = Client.GetNamedObject("QuestLogFrame")
    if not log or not Client.IsObjectShown(log) then
        return
    end
    local tracker = Tracker()
    if not tracker then
        return
    end

    local standaloneMarks, unrealUIMarks = 0, 0
    local rowIndex = 1
    local misses = 0
    while rowIndex <= MAX_LOG_ROWS and misses < 3 do
        local row = Client.GetNamedObject("QuestLogTitle" .. tostring(rowIndex))
        if not row then
            misses = misses + 1
        else
            misses = 0
            local quest = nil
            if Client.IsObjectShown(row) then
                quest = QuestFromRow(row)
            end
            local style = Client.SetQuestLogTrackMark(rowIndex,
                quest and tracker:IsTracked(quest))
            if style == "unrealUI" then
                unrealUIMarks = unrealUIMarks + 1
            elseif style == "standalone" then
                standaloneMarks = standaloneMarks + 1
            end
        end
        rowIndex = rowIndex + 1
    end
    self.standaloneMarks = standaloneMarks
    self.unrealUIMarks = unrealUIMarks
end

function QuestLogTracking:GetReport()
    return {
        chainedRows = self.chainedRows,
        shiftClicks = self.shiftClicks,
        standaloneMarks = self.standaloneMarks,
        -- Kept for existing diagnostic consumers; the value now counts the
        -- standalone owned frames rather than native Check textures.
        nativeMarks = self.standaloneMarks,
        unrealUIMarks = self.unrealUIMarks,
    }
end

function QuestLogTracking:OnInit()
    UQ:DeclareCapability("questLogUnlimitedTracking", "unverified",
        "Shift-click is chained onto native QuestLogTitle rows and the unlimited saved tracking set "
        .. "is rendered through an owned fixed accent Frame or unrealUI's detected uuiTrackMark; "
        .. "the standalone owned-frame path needs one in-game visual confirmation")
end

function QuestLogTracking:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    self:InstallRows()
    self:RefreshMarks()
    driver:Schedule("questlog.tracking.rows", 1.0, function()
        QuestLogTracking:InstallRows()
    end)
    driver:Schedule("questlog.tracking.marks", 0.2, function()
        QuestLogTracking:RefreshMarks()
    end)
end
