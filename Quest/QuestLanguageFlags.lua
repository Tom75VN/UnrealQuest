--[[
UnrealQuest / Quest/QuestLanguageFlags.lua

The per-quest language flag row, and nothing else. One row of small flags in
the top-right corner of a quest panel: one flag per language THAT quest can be
read in, full opacity on the one it is in, 30% on the others, 95% under the
cursor. Clicking one puts that single quest in that language and leaves the
account-wide setting alone.

Two panels ask for this row, and they are not the same frame, do not share a
parent, and do not resolve their quest the same way:

  * the quest log detail pane (Quest/QuestLogButtons.lua), where the quest is
    the selected row and the row is parented to QuestLogFrame;
  * the quest-giver's offer and turn-in windows
    (Quest/QuestGiverTranslation.lua), where there is no log row at all and the
    row is parented to QuestFrame.

Everything they DO share lives here: the roster, the buttons, the tooltip, the
right-to-left layout and the three shades. A caller hands over its own key, its
own anchor and its own placer, and gets a row back. That is the whole contract,
and it exists because the second panel would otherwise have been a copy of the
first with four names changed -- the kind of copy that drifts.

A row's buttons are created once and never destroyed, because this client
cannot destroy a frame. Each row therefore owns its own buttons under its own
widget names rather than sharing one set: the two panels can be open at the
same time, and one button cannot be in two places.

The roster -- which flags exist and in what order -- is fixed for the session
and shared by every row. WHICH of them a given quest offers is decided per
refresh from the calling module's own GetLanguageChoices, so a quest with no
bundled row for a language simply has no flag for it and the row closes the
gap rather than leaving a hole.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Flags = UQ:NewModule("QuestLanguageFlags")

-- 30% off the settings header's 18x14 and its 3-pixel gap, because this row
-- sits inside the quest text rather than in a chrome strip of its own. The
-- inset is measured from the panel's top-right corner and kept small: the
-- scroll bar sits outside that corner.
local FLAG_WIDTH = 13
local FLAG_HEIGHT = 10
local FLAG_GAP = 2
local FLAG_INSET_X = -6
local FLAG_INSET_Y = -4

-- The settings row's own three shades, for the same reason it has them:
-- selection is communicated by opacity alone, and pointing at the current
-- choice must never make it look weaker than the others.
local FLAG_SHADE_SELECTED = 1
local FLAG_SHADE_IDLE = 0.3
local FLAG_SHADE_HOVER = 0.95

Flags.codes = nil
Flags.rows = {}

-- The roster is fixed for the session: the languages this addon carries flags
-- for, in the settings row's order, plus the client's own locale when it is
-- not one of them.
local function Roster()
    if Flags.codes then
        return Flags.codes
    end
    local languages = UQ.GetLanguages()
    if not languages then
        return nil
    end
    local codes = {}
    local seen = {}
    local index = 1
    local total = table.getn(languages)
    while index <= total do
        local code = languages[index].code
        table.insert(codes, code)
        seen[code] = true
        index = index + 1
    end
    local clientLanguage = Client.GetLocale()
    if type(clientLanguage) == "string" and not seen[clientLanguage] then
        table.insert(codes, 1, clientLanguage)
    end
    Flags.codes = codes
    return codes
end

local function RowFor(key)
    local row = Flags.rows[key]
    if not row then
        row = {}
        Flags.rows[key] = row
    end
    return row
end

local function ShowTooltip(row, button)
    local code = button.unrealQuestLanguage
    if not row.quest or type(code) ~= "string" then
        return
    end
    local native = code == Client.GetLocale()
    local lines = {
        { text = UQ.GetLanguageLabel(code), r = UQ.colors.accent[1],
          g = UQ.colors.accent[2], b = UQ.colors.accent[3] },
        { text = native and UQ.L("QUESTLOG_FLAG_NATIVE")
            or UQ.L("QUESTLOG_FLAG_TRANSLATED"), r = 0.9, g = 0.9, b = 0.9 },
        { text = UQ.L("QUESTLOG_FLAG_ONLY_THIS_QUEST"), r = 0.7, g = 0.7, b = 0.7 },
    }
    Client.ShowGameTooltip(button, lines, "ANCHOR_LEFT")
end

-- Built once per row; the caller's own placer then reparents each button to
-- the frame that panel wants and keeps it there. Each is created WITH artwork
-- rather than with the ASCII badge: Client.CreateFlagButton only makes the
-- icon texture when it is handed a path, and a flag that started as a badge
-- could never grow one.
local function EnsureButtons(row, namePrefix, parent)
    if row.buttons then
        return row.buttons
    end
    local codes = Roster()
    if not codes or not parent then
        return nil
    end

    local buttons = {}
    local index = 1
    local total = table.getn(codes)
    while index <= total do
        -- Captured per iteration: the closures below outlive it.
        local code = codes[index]
        local button = Client.CreateFlagButton(parent, namePrefix .. code,
            UQ.FlagTexture(code), UQ.GetLanguageBadge(code),
            FLAG_WIDTH, FLAG_HEIGHT)
        if button then
            button.unrealQuestLanguage = code
            Client.SetObjectScript(button, "OnClick", function()
                local translation = row.translation
                local quest = row.quest
                if not translation or not quest then
                    return
                end
                if not translation:SetQuestLanguage(quest, code) then
                    return
                end
                if row.onChanged then
                    row.onChanged()
                end
                ShowTooltip(row, button)
            end)
            Client.SetObjectScript(button, "OnEnter", function()
                if not button.unrealQuestSelected then
                    Client.SetFlagButtonShade(button, FLAG_SHADE_HOVER, false)
                end
                ShowTooltip(row, button)
            end)
            Client.SetObjectScript(button, "OnLeave", function()
                if not button.unrealQuestSelected then
                    Client.SetFlagButtonShade(button, FLAG_SHADE_IDLE, false)
                end
                Client.HideGameTooltip(button)
            end)
            Client.HideObject(button)
            buttons[code] = button
        end
        index = index + 1
    end

    row.buttons = buttons
    return buttons
end

local function HideRow(row)
    local buttons = row.buttons
    if not buttons then
        return
    end
    local codes = Flags.codes
    local index = 1
    local total = codes and table.getn(codes) or 0
    while index <= total do
        local button = buttons[codes[index]]
        if button then
            Client.HideObject(button)
        end
        index = index + 1
    end
end

-- One row, refreshed for whatever quest that panel is showing.
--
--   spec.key         identity of this row, so two panels keep separate buttons
--   spec.namePrefix  widget name stem; the language code is appended
--   spec.quest       the quest table (needs .questId), or nil to hide the row
--   spec.anchor      the frame the row is anchored to, top-right corner
--   spec.place       function(button, anchor, offsetX, offsetY) -> boolean,
--                    the caller's own parenting rule -- see the two
--                    Client.PlaceQuest*Flag notes for why it is not one rule
--   spec.translation module answering GetLanguageChoices / GetQuestLanguage /
--                    CanChooseLanguage / SetQuestLanguage for that panel
--   spec.onChanged   called after a click actually changed the language
--   spec.insetX/Y    optional, overriding the row's own corner inset
--
-- The whole row is drawn only when there is a choice: an unambiguous quest ID
-- and at least one bundled language beside the client's own. A lone flag that
-- does nothing when clicked is worse than no row at all.
function Flags:Refresh(spec)
    if not spec or type(spec.key) ~= "string" then
        return false
    end
    local row = RowFor(spec.key)
    row.translation = spec.translation
    row.onChanged = spec.onChanged

    local translation = spec.translation
    local quest = spec.quest
    local anchor = spec.anchor
    if not translation or not quest or not anchor
        or not translation:CanChooseLanguage(quest) then
        row.quest = nil
        HideRow(row)
        return false
    end
    row.quest = quest

    local buttons = EnsureButtons(row,
        spec.namePrefix or "UnrealQuestLanguageFlag", anchor)
    local codes = Flags.codes
    if not buttons or not codes then
        return false
    end

    -- Membership, not order: the row reads in the roster's order, while
    -- GetLanguageChoices answers in the module's own (client language first).
    local offered = {}
    local choices = translation:GetLanguageChoices(quest)
    local index = 1
    local total = choices and table.getn(choices) or 0
    while index <= total do
        offered[choices[index]] = true
        index = index + 1
    end

    -- Two passes, because the position of the first flag depends on how many
    -- follow it: a quest missing one language must leave no hole in the row.
    local shown = {}
    index = 1
    total = table.getn(codes)
    while index <= total do
        local code = codes[index]
        local button = buttons[code]
        if button and offered[code] then
            table.insert(shown, button)
        elseif button then
            Client.HideObject(button)
        end
        index = index + 1
    end

    local insetX = spec.insetX or FLAG_INSET_X
    local insetY = spec.insetY or FLAG_INSET_Y
    local current = translation:GetQuestLanguage(quest)
    local count = table.getn(shown)
    local placed = 0
    index = 1
    while index <= count do
        local button = shown[index]
        -- Right to left from the panel's right edge, exactly as the settings
        -- header lays its own row out.
        local offsetX = insetX - (count - index) * (FLAG_WIDTH + FLAG_GAP)
        if spec.place and spec.place(button, anchor, offsetX, insetY) then
            local selected = button.unrealQuestLanguage == current
            button.unrealQuestSelected = selected
            Client.SetFlagButtonShade(button,
                selected and FLAG_SHADE_SELECTED or FLAG_SHADE_IDLE, selected)
            Client.ShowObject(button)
            placed = placed + 1
        else
            Client.HideObject(button)
        end
        index = index + 1
    end
    return placed > 0
end

-- Takes a row off screen without asking the panel anything, for a caller whose
-- panel has just closed.
function Flags:Hide(key)
    local row = Flags.rows[key]
    if not row then
        return
    end
    row.quest = nil
    HideRow(row)
end
