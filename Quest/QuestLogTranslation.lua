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

Stock FrameXML owns these FontStrings and may rewrite them on selection,
scroll or quest progress. A small polling pass therefore reapplies only changed
display strings.

GOING BACK TO THE CLIENT'S OWN TEXT IS THIS MODULE'S JOB, NOT THE CLIENT'S.
The first version of this asked QuestLog_Update to repaint and assumed the
detail pane came with it. It does not: knowledge.json /
questlog.native_refresh_font_colours (USER_CONFIRMED_INGAME) names
QuestLog_Update and QuestLog_UpdateQuestDetails as two separate repaint entry
points here, and only the second one owns these three fields. The visible
symptom was exact -- switching a quest between two translations worked, because
this module writes both, while switching back to the client's language changed
nothing at all, because nothing wrote that.

So each field remembers the text that was on it before this module replaced it,
and restoring writes that back. Both refresh calls are still made first, since
they also repair everything else the client owns (row text, fonts, colours),
but nothing here depends on either landing -- the same rule the rest of the
addon follows about client behaviour. The remembered text is only ever written
back to a field that is STILL showing this module's own string: once the client
has repainted for any reason, what is on screen is fresher than the record, and
the record is replaced rather than reapplied. That is also what makes changing
the selected quest safe, since a stale record would otherwise put the previous
quest's description on the new one.

WHICH LANGUAGE ONE QUEST IS IN.

The account-wide setting is not the last word. A per-quest override
(UQ.GetQuestLanguageOverride, Core/Locale.lua) wins over it, and it holds a
LANGUAGE CODE rather than a yes/no: the flag ROW in the detail pane's
top-right corner offers this quest the languages it actually has, one flag
each, and the client's own locale is one of them -- meaning the text the server
sent. That is why the row is useful on a client whose locale already matches
the addon's interface language, the common case, where a yes/no toggle would
have had nothing to offer and would never have appeared at all.

This module owns the questions that row asks -- GetQuestLanguage,
GetLanguageChoices, CanChooseLanguage and SetQuestLanguage -- because they are
the same ones this pane already answers for itself; the widgets live in
Quest/QuestLogButtons.lua with the pane's other per-quest controls.

Choosing a language reapplies the pane in the SAME call rather than waiting for
the next poll, so the click reads as instant; there is no reload anywhere in this path,
since nothing here is written to a saved variable and every other surface
showing that quest re-reads the policy on its own poll.
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

-- Which language this quest is being read in right now: its own override
-- first, then the account-wide setting, then the client's own locale, which is
-- what "not translated" resolves to.
local function QuestLanguage(quest)
    local clientLanguage = Client.GetLocale()
    if quest and type(quest.questId) == "number" then
        local override = UQ.GetQuestLanguageOverride
            and UQ.GetQuestLanguageOverride(quest.questId)
        if type(override) == "string" then
            return override
        end
    end
    local config = UQ:GetModule("Config")
    if config and config:Get("translateQuestTitles") == false then
        return clientLanguage
    end
    local selected = UQ.GetLanguage and UQ.GetLanguage()
    if type(selected) == "string" then
        return selected
    end
    return clientLanguage
end

-- Every language this quest can be read in. The client's locale comes FIRST
-- and is included unconditionally: it needs no bundled row, it is the text the
-- server actually sent, and a player who cannot read the language they picked
-- has to have one flag that always takes them back. The rest are the languages
-- this addon carries flags and catalogs for, in the settings row's own order,
-- and only those with a real row for this quest.
local function LanguageChoices(quest)
    if not quest or type(quest.questId) ~= "number" then
        return nil
    end
    local database = UQ:GetModule("Database")
    if not database then
        return nil
    end

    local codes = {}
    local seen = {}
    local clientLanguage = Client.GetLocale()
    if type(clientLanguage) == "string" then
        table.insert(codes, clientLanguage)
        seen[clientLanguage] = true
    end
    local languages = UQ.GetLanguages()
    local index = 1
    local total = languages and table.getn(languages) or 0
    while index <= total do
        local code = languages[index].code
        if not seen[code]
            and database:GetQuestTextForLanguage(quest.questId, code) then
            table.insert(codes, code)
            seen[code] = true
        end
        index = index + 1
    end
    return codes
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

-- Writes one field's remembered native text back, but only while that field is
-- still showing what this module put there. Returns true when the field is
-- known to be native afterwards -- including the case where the client had
-- already repainted it itself.
local function RestoreField(spec)
    local object = Client.GetNamedObject(spec.name)
    if not object then
        return true
    end
    local applied = object.unrealQuestAppliedText
    object.unrealQuestAppliedText = nil
    if type(applied) ~= "string" then
        return true
    end
    -- Normalised the same way the apply pass records it: an empty field reads
    -- back as nil here and as "" there, and a mismatch between the two would
    -- make every field look like the client had repainted it.
    if (Client.GetObjectText(object) or "") ~= applied then
        -- The client repainted; its text is the fresher answer and the record
        -- is stale by definition.
        object.unrealQuestNativeText = nil
        return true
    end
    local native = object.unrealQuestNativeText
    if type(native) ~= "string" then
        return false
    end
    return Client.SetNativeObjectText(object, native)
end

local function RestoreNative()
    if QuestLogTranslation.appliedSignature then
        -- Accelerators, not the mechanism: these repair the row text, fonts
        -- and colours the client owns. QuestLog_Update alone does not touch
        -- the three detail fields -- see the header.
        Client.RefreshQuestLog()
        Client.RefreshQuestLogDetails()

        local index = 1
        local total = table.getn(FIELDS)
        local restored = true
        while index <= total do
            if not RestoreField(FIELDS[index]) then
                restored = false
            end
            index = index + 1
        end
        if not restored then
            -- Keep the signature so the next poll retries. Clearing it with a
            -- field still translated would make stale text look native.
            return false
        end
        Client.UpdateScrollChildRect(Client.GetNamedObject(SCROLL_NAME))
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

    local database = UQ:GetModule("Database")
    local quest, selection = SelectedQuest()
    local clientLanguage = Client.GetLocale()
    -- QuestLanguage is asked about THIS quest, so the language cannot be
    -- resolved before the selection is.
    local language = QuestLanguage(quest)
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
            -- Normalised to a string: an empty detail field reads back as
            -- nil, and comparing nil against an unset record would decide the
            -- client's own text did not need recording -- leaving nothing to
            -- restore later and, once a restore then refused to complete, no
            -- way back at all.
            local currentText = Client.GetObjectText(object) or ""
            -- Anything that is not this module's own string is the client's
            -- own text, and it is what has to go back on a restore. Recorded
            -- here rather than on the first replacement, so a repaint between
            -- two polls updates the record instead of preserving a stale one.
            if currentText ~= object.unrealQuestAppliedText then
                object.unrealQuestNativeText = currentText
            end
            local nativeText = object.unrealQuestNativeText
            local displayText = database:GetQuestDisplayText(
                quest, spec.field, nativeText)
            if type(displayText) == "string" and displayText ~= ""
                and displayText ~= currentText
                and Client.SetNativeObjectText(object, displayText) then
                object.unrealQuestAppliedText = displayText
                translated = translated + 1
            elseif type(displayText) == "string" and displayText ~= ""
                and displayText == currentText then
                -- Already on screen: either this module wrote it on an earlier
                -- poll, or the desired translation survived a stock refresh.
                object.unrealQuestAppliedText = displayText
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

-- What the detail pane's flag asks ------------------------------------------

function QuestLogTranslation:GetQuestLanguage(quest)
    return QuestLanguage(quest)
end

function QuestLogTranslation:GetLanguageChoices(quest)
    return LanguageChoices(quest)
end

-- Is there a choice to offer? A quest with no unambiguous ID, or one whose
-- only available language is the client's own, gets no row at all -- rather
-- than a lone flag that does nothing when clicked.
function QuestLogTranslation:CanChooseLanguage(quest)
    local codes = LanguageChoices(quest)
    return codes ~= nil and table.getn(codes) >= 2
end

-- Puts this quest in one named language and reapplies the pane immediately.
-- Returns true when something actually moved; asking for the language it is
-- already in is not an error, it just changes nothing.
function QuestLogTranslation:SetQuestLanguage(quest, code)
    if not quest or type(quest.questId) ~= "number" or type(code) ~= "string" then
        return false
    end
    if code == QuestLanguage(quest) then
        return false
    end
    if not UQ.SetQuestLanguageOverride
        or not UQ.SetQuestLanguageOverride(quest.questId, code) then
        return false
    end
    self:Refresh()
    return true
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
