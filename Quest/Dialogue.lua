--[[
UnrealQuest / Quest/Dialogue.lua

Addon-owned replacement for the stock gossip and quest interaction flow.
Events accelerate mode changes; the shared Driver re-reads live client state.
The stock roots remain intact and are restored immediately when the option is
disabled.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Dialogue = UQ:NewModule("Dialogue")

local POLL_INTERVAL = 0.10
local TYPEWRITER_INTERVAL = 0.014625
local TYPEWRITER_SHORT_PAUSE = 0.07
local TYPEWRITER_LONG_PAUSE = 0.15
-- How long after Escape closed the card a game menu still counts as opened by
-- that same press (Dialogue:CloseOnGameMenu).
local ESCAPE_MENU_WINDOW = 0.5
-- Longest wait for the page a gossip/greeting row opens before the poll reads
-- the dialogue without a hint again (Dialogue:SelectRow). The measured answer
-- took about 28 frames (questflash.v1).
local ROW_ANSWER_WAIT = 2.0
local INSPECTOR_PAGE_SIZE = 15

Dialogue.frame = nil
Dialogue.modeHint = nil
Dialogue.mode = nil
Dialogue.selectedChoice = 0
Dialogue.lastSignature = nil
Dialogue.lastNativeKind = nil
Dialogue.closed = nil
Dialogue.closePending = nil
Dialogue.rowPending = nil
Dialogue.questSignal = nil
Dialogue.gossipSignal = nil
Dialogue.pageKey = nil
Dialogue.pageIndex = 1
Dialogue.pages = nil
Dialogue.inspectorOpen = nil
Dialogue.inspectorPage = 1
Dialogue.interactionKey = nil
Dialogue.sourceText = {}
Dialogue.revealKey = nil
Dialogue.revealCharacters = nil
Dialogue.revealCount = 0
Dialogue.revealNextAt = nil
Dialogue.revealing = nil

local function Enabled()
    local config = UQ:GetModule("Config")
    return not config or config:Get("immersiveDialogue") ~= false
end

-- The card's look, including the flat compact Minimal skin.
local function Theme()
    local config = UQ:GetModule("Config")
    local theme = config and config:Get("dialogueTheme")
    if theme == "parchment" or theme == "alliance-light" or theme == "alliance"
        or theme == "horde-light" or theme == "horde" or theme == "minimal" then
        return theme
    end
    return "minimal"
end

-- Off by default: only quest givers get the card (see TakesInteraction).
local function AllNpcs()
    local config = UQ:GetModule("Config")
    return config and config:Get("immersiveDialogueAllNpcs") == true
end

-- Whether the dialogue takes this interaction. Every quest page comes from a
-- quest giver; a gossip window counts as one only while it lists a quest to
-- take or hand in. Decided when the card would open: a conversation the card
-- already holds keeps it, so a gossip page without quests reached from a
-- quest giver does not drop back to the stock window mid-conversation.
local function TakesInteraction(mode, holding)
    if mode ~= "gossip" or holding or AllNpcs() then return true end
    local rows = Client.GetQuestDialogueGossipRows()
    local index = 1
    while index <= table.getn(rows) do
        local kind = rows[index].kind
        if kind == "gossipAvailable" or kind == "gossipActive" then return true end
        index = index + 1
    end
    return false
end

local function AppendText(first, second)
    if type(second) ~= "string" or second == "" then return first end
    if type(first) ~= "string" or first == "" then return second end
    return first .. "\n\n" .. second
end

local function Utf8Characters(text)
    local characters = {}
    local index = 1
    local total = string.len(text or "")
    while index <= total do
        local first = string.byte(text, index) or 0
        local width = 1
        if first >= 240 then
            width = 4
        elseif first >= 224 then
            width = 3
        elseif first >= 192 then
            width = 2
        end
        if index + width - 1 > total then width = 1 end
        table.insert(characters, string.sub(text, index, index + width - 1))
        index = index + width
    end
    return characters
end

-- A 2-byte character (Cyrillic, and Latin with accents) draws about as wide
-- as an ASCII letter; only 3- and 4-byte ones (CJK script) take two columns.
-- Counting Cyrillic as two filled a Russian page at half its lines (user
-- report).
local function CharacterWidth(character)
    return string.len(character) >= 3 and 2 or 1
end

-- A word: a run of characters up to a space or a line break. A 3- or 4-byte
-- character (CJK script, written without spaces) is a word of its own, so
-- such text may still break between any two characters. Returns the word's
-- characters, its width in budget columns and the index after it.
local function NextWord(characters, index)
    local first = characters[index]
    if string.len(first) >= 3 then return { first }, 2, index + 1 end
    local word = {}
    local width = 0
    local total = table.getn(characters)
    while index <= total do
        local character = characters[index]
        if character == " " or character == "\n" or string.len(character) >= 3 then break end
        table.insert(word, character)
        width = width + CharacterWidth(character)
        index = index + 1
    end
    return word, width, index
end

-- One page holds what the active theme's body box holds
-- (Client.GetQuestDialogueTextBudget). Words are laid out whole and a page
-- never ends inside one: a word that would run past the page's last line
-- starts the next page. Only a word wider than a whole line wraps inside
-- itself, as the client's own word wrap would break it.
local function Paginate(text, card)
    local columns, lines = Client.GetQuestDialogueTextBudget(Dialogue.frame, card)
    local characters = Utf8Characters(text)
    local total = table.getn(characters)
    local pages = {}
    local page = {}
    local line = 1
    local column = 0
    local index = 1
    while index <= total do
        local character = characters[index]
        if character == "\n" then
            if line >= lines and table.getn(page) > 0 then
                table.insert(page, character)
                table.insert(pages, table.concat(page))
                page = {}
                line = 1
                column = 0
            elseif table.getn(page) == 0 and table.getn(pages) > 0 then
                local pageCount = table.getn(pages)
                pages[pageCount] = pages[pageCount] .. character
                line = 1
                column = 0
            else
                table.insert(page, character)
                line = line + 1
                column = 0
            end
            index = index + 1
        elseif character == " " then
            -- A space the line has no room for is where the client wraps;
            -- the next word decides whether that wrap also ends the page.
            if column + 1 > columns then
                line = line + 1
                column = 0
            else
                column = column + 1
            end
            table.insert(page, character)
            index = index + 1
        else
            local word, width, after = NextWord(characters, index)
            if column > 0 and column + width > columns then
                line = line + 1
                column = 0
            end
            local used = 1
            if width > columns then used = math.ceil(width / columns) end
            if line + used - 1 > lines and table.getn(page) > 0 then
                table.insert(pages, table.concat(page))
                page = {}
                line = 1
                column = 0
            end
            line = line + used - 1
            if used > 1 then
                column = width - (used - 1) * columns
            else
                column = column + width
            end
            local wordIndex = 1
            while wordIndex <= table.getn(word) do
                table.insert(page, word[wordIndex])
                wordIndex = wordIndex + 1
            end
            index = after
        end
    end
    if table.getn(page) > 0 or table.getn(pages) == 0 then
        table.insert(pages, table.concat(page))
    end
    return pages
end

-- `text` without its blank lines (a line of nothing but spaces counts as
-- one) or the line breaks around it: quest objectives part their steps with
-- an empty line ("Kill 12 Vile Familiars.\n\nReturn to ..."), which the
-- objectives strip has no height to spare for (user request).
local function CompactLines(text)
    if type(text) ~= "string" then return text end
    text = string.gsub(text, "\r", "")
    local count = 1
    while count > 0 do
        text, count = string.gsub(text, "\n[ \t]*\n", "\n")
    end
    text = string.gsub(text, "^[\n \t]+", "")
    text = string.gsub(text, "[\n \t]+$", "")
    return text
end

-- The lines `text` wraps to at `columns`, by Paginate's rules on one
-- endless page: a word the line has no room for starts the next one.
local function CountLines(text, columns)
    local characters = Utf8Characters(text)
    local total = table.getn(characters)
    local line = 1
    local column = 0
    local index = 1
    while index <= total do
        local character = characters[index]
        if character == "\n" then
            line = line + 1
            column = 0
            index = index + 1
        elseif character == " " then
            if column + 1 > columns then
                line = line + 1
                column = 0
            else
                column = column + 1
            end
            index = index + 1
        else
            local _, width, after = NextWord(characters, index)
            if column > 0 and column + width > columns then
                line = line + 1
                column = 0
            end
            local used = 1
            if width > columns then used = math.ceil(width / columns) end
            line = line + used - 1
            if used > 1 then
                column = width - (used - 1) * columns
            else
                column = column + width
            end
            index = after
        end
    end
    return line
end

local function ApplyPages(view, key, text)
    if Dialogue.pageKey ~= key then
        Dialogue.pageKey = key
        Dialogue.pageIndex = 1
        Dialogue.pages = Paginate(text or "", view.card)
    end
    local pages = Dialogue.pages or { text or "" }
    local count = table.getn(pages)
    if Dialogue.pageIndex < 1 then Dialogue.pageIndex = 1 end
    if Dialogue.pageIndex > count then Dialogue.pageIndex = count end
    view.body = pages[Dialogue.pageIndex] or ""
    view.pageIndex = Dialogue.pageIndex
    view.pageCount = count
    view.hasPreviousPage = Dialogue.pageIndex > 1
    view.hasNextPage = Dialogue.pageIndex < count
end

local function RevealDelay(character)
    local interval = TYPEWRITER_INTERVAL
    if character == "." or character == "!" or character == "?"
        or character == "。" or character == "！" or character == "？" then
        return interval + TYPEWRITER_LONG_PAUSE
    end
    if character == "," or character == ";" or character == ":"
        or character == "，" or character == "；" or character == "："
        or character == "\n" then
        return interval + TYPEWRITER_SHORT_PAUSE
    end
    return interval
end

local function PrepareTextReveal(view)
    local text = type(view.body) == "string" and view.body or ""
    local key = tostring(view.interactionKey or "") .. "\031"
        .. tostring(view.pageIndex or 1) .. "\031" .. text
    if Dialogue.revealKey ~= key then
        Client.ResetQuestDialogueLetters(Dialogue.frame)
        Dialogue.revealKey = key
        Dialogue.revealCharacters = Utf8Characters(text)
        Dialogue.revealCount = 0
        Dialogue.revealNextAt = Client.Now() or 0
        Dialogue.revealing = table.getn(Dialogue.revealCharacters) > 0 and true or nil
    end
    local characters = Dialogue.revealCharacters or {}
    view.revealCharacters = characters
    view.revealCount = Dialogue.revealCount or 0
    view.bodyRevealing = Dialogue.revealing and true or false
end

-- What clicking the card does, after Immersion's TalkBox (inputs.accept,
-- TalkBox:OnLeftClick, TalkBox:OnClick). A left click turns the page while
-- one is left, otherwise takes `primary`, the window's next step. A right
-- click turns the page, or on the last page goes back to the first (the
-- repeat), or opens the reward inspector when there is nothing to page.
local function SetClickActions(view, primary)
    if view.hasNextPage then
        view.clickAction = "nextPage"
        view.rightClickAction = "nextPage"
        return
    end
    view.clickAction = primary
    if (view.pageCount or 1) > 1 then
        view.rightClickAction = "firstPage"
    elseif view.mode == "reward" then
        view.rightClickAction = "inspectRewards"
    end
end

-- Immersion's TitleButtons:GetBestOption for a click on a card with several
-- rows: a quest ready to hand in, then a quest to pick up. Plain gossip lines
-- are a real choice and are never taken for the player.
local function BestRow(rows)
    local best, bestRank
    local index = 1
    while index <= table.getn(rows) do
        local row = rows[index]
        local kind = row.payload and row.payload.kind
        local rank
        if (kind == "gossipActive" or kind == "active") and row.complete then
            rank = 1
        elseif kind == "gossipAvailable" or kind == "available" then
            rank = 2
        end
        if rank and (not bestRank or rank < bestRank) then
            best, bestRank = row.payload, rank
        end
        index = index + 1
    end
    return best
end

-- The left-click step for a gossip or greeting list (inputs.accept): close
-- an empty list, take the only row, or the best quest row of several.
local function ListClickAction(view, close)
    local selectable = {}
    local index = 1
    while index <= table.getn(view.rows) do
        local payload = view.rows[index].payload
        local kind = payload and payload.kind
        if kind == "gossipOption" or kind == "gossipAvailable"
            or kind == "gossipActive" or kind == "available" or kind == "active" then
            table.insert(selectable, view.rows[index])
        end
        index = index + 1
    end
    if table.getn(selectable) == 0 then return close end
    if table.getn(selectable) == 1 then
        view.clickPayload = selectable[1].payload
        return "selectRow"
    end
    view.clickPayload = BestRow(selectable)
    return view.clickPayload and "selectRow" or nil
end

local function QuestContext(title)
    local match = UQ:GetModule("QuestMatch")
    local database = UQ:GetModule("Database")
    local questId = match and match:ResolveGiverQuestId() or nil
    if type(questId) ~= "number" or not database then
        return nil, database, nil
    end
    local quest = { questId = questId, title = title }
    local language = UQ.GetLanguage and UQ.GetLanguage() or nil
    local translation = UQ:GetModule("QuestLogTranslation")
    if translation and translation.GetQuestLanguage then
        language = translation:GetQuestLanguage(quest) or language
    end
    return quest, database, language
end

-- The zone backdrop (Data/DialogueBackdrops.lua) for an area, or for the
-- zone enclosing it.
local function AreaBackdrop(backdrops, mapContext, areaId)
    if type(areaId) ~= "number" then return nil end
    if backdrops[areaId] then return backdrops[areaId] end
    local parentId = mapContext and mapContext:ResolveEnclosingArea(areaId)
    return parentId and backdrops[parentId] or nil
end

-- The portrait backdrop for a conversation: the quest's zone (where its
-- objectives are recorded, else its turn-in), else the zone the player
-- stands in, else nil for the theme's default. The NPC's race would be the
-- other key, but UnitRace is nil on every NPC here
-- (units.npc_race_nil_creaturetype_available).
local function ResolveBackdrop(questId)
    local backdrops = UQ.dialogueBackdrops
    if type(backdrops) ~= "table" or next(backdrops) == nil then return nil end
    local mapContext = UQ:GetModule("MapContext")
    local database = UQ:GetModule("Database")
    if type(questId) == "number" and database and database.available then
        local areas = database:GetQuestAreaIds(questId, false)
        if table.getn(areas) == 0 then areas = database:GetQuestAreaIds(questId, true) end
        local name = AreaBackdrop(backdrops, mapContext, areas[1])
        if name then return name end
    end
    if not mapContext then return nil end
    local _, areaId = mapContext:GetStandingZone()
    return AreaBackdrop(backdrops, mapContext, areaId)
end

local function QuestText(database, quest, field, fallback)
    if database and quest then
        return database:GetQuestDisplayText(quest, field, fallback) or fallback
    end
    return fallback
end

local function ItemName(database, language, fallback)
    if database and type(language) == "string" then
        return database:GetItemDisplayNameForLanguage(fallback, language) or fallback
    end
    return fallback
end

local function MoneyText(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper - gold * 10000) / 100)
    local remainder = copper - gold * 10000 - silver * 100
    return UQ.L("DIALOGUE_MONEY", gold, silver, remainder)
end

-- The money line under the item tiles, worded as the stock reward panel
-- does: "You will also receive:" after items, "You will receive:" alone.
-- Only the label is text: the panel draws the amount after it as gold,
-- silver and copper coins (Client.RenderQuestDialogueTurnIn), so the line is
-- { text, money } rather than a string.
local function MoneyLine(money, afterItems)
    local label = UQ.L(afterItems and "DIALOGUE_ALSO_RECEIVE_MONEY" or "DIALOGUE_RECEIVE_MONEY", "")
    label = string.gsub(label, "%s+$", "")
    return { text = label, money = money }
end

local function ReadSourceText(key, reader)
    local cached = Dialogue.sourceText[key]
    if type(cached) == "string" then return cached end
    local value = reader()
    if type(value) == "string" and value ~= "" then
        Dialogue.sourceText[key] = value
        return value
    end
    return nil
end

-- A quest row carries only its title and level, so the quest is resolved from
-- those two alone (no log index: the quest may not be in the log). Only a
-- resolved quest can earn the dungeon/elite "+" in UQ.FormatQuestLevel.
local function QuestRowText(row)
    if type(row.level) == "number" and row.level > 0 then
        local questId = nil
        local match = UQ:GetModule("QuestMatch")
        if match and type(row.text) == "string" and row.text ~= "" then
            questId = match:Resolve(row.text, row.level)
        end
        return UQ.L("DIALOGUE_QUEST_LEVEL",
            UQ.FormatQuestLevel(row.level, questId), row.text or "")
    end
    return row.text or ""
end

local function ItemRow(item, enabled, selectedChoice, database, language, mark)
    local name = ItemName(database, language, item.name)
    if item.count and item.count > 1 then name = name .. "  x" .. tostring(item.count) end
    return {
        text = name,
        icon = item.texture,
        enabled = enabled and true or false,
        selected = item.rewardType == "choice" and selectedChoice == item.index,
        rewardType = item.rewardType,
        rewardIndex = item.index,
        quality = item.quality,
        usable = item.usable,
        advisor = mark,
        payload = {
            kind = item.rewardType == "choice" and "rewardChoice" or "item",
            index = item.index,
        },
    }
end

-- The have/need counters the quest log shows for one required item, read
-- from QuestState's live objective lines (the same counters the tracker
-- draws). Returns have, need, finished; nil when no line names the item --
-- a missing counter is unknown, never zero.
local function ObjectiveCounts(liveTitle, itemName)
    local questState = UQ:GetModule("QuestState")
    local objectiveMatch = UQ:GetModule("ObjectiveMatch")
    local quest = questState and questState:GetQuestByTitle(liveTitle)
    local objectives = quest and quest.objectives
    local itemKey = UQ.NameKey(itemName)
    if not objectives or not objectiveMatch or not itemKey then return nil end
    local index = 1
    while index <= table.getn(objectives) do
        local objective = objectives[index]
        if objective then
            local name, have, need = objectiveMatch:ParseLine(
                objective.text, objective.objectiveType)
            if name and UQ.NameKey(name) == itemKey then
                return have, need, objective.finished
            end
        end
        index = index + 1
    end
    return nil
end

-- The quest's objectives as its quest-log lines count them ("Kobold Vermin
-- slain: 6/10"), from QuestState's live objective lines, joined by
-- `separator`. nil when the log names no objective for the title.
local function LogObjectiveText(liveTitle, separator)
    local questState = UQ:GetModule("QuestState")
    local quest = questState and questState:GetQuestByTitle(liveTitle)
    local objectives = quest and quest.objectives
    if not objectives then return nil end
    local lines = {}
    local index = 1
    while index <= table.getn(objectives) do
        local objective = objectives[index]
        if objective and type(objective.text) == "string" and objective.text ~= "" then
            table.insert(lines, objective.text)
        end
        index = index + 1
    end
    if table.getn(lines) == 0 then return nil end
    return table.concat(lines, separator)
end

-- The progress page's required items with their have/need counts
-- (Immersion's Elements:ShowProgress lists the items and the money).
-- IsQuestCompletable is the authority: when it says yes, every item reads as
-- in hand whatever the counters say. Otherwise each item takes its quest-log
-- counter; an item no log line names has no `have` and shows its need only.
-- Returns nil when the quest asks for nothing.
local function BuildRequirements(liveTitle, database, language, completable)
    local required = Client.GetQuestDialogueItems("required")
    local requiredMoney = Client.GetQuestDialogueRequiredMoney()
    if table.getn(required) == 0 and requiredMoney <= 0 then return nil end
    local requirements = { items = {} }
    local index = 1
    while index <= table.getn(required) do
        local item = required[index]
        local need = item.count or 1
        local have, counterNeed, finished = ObjectiveCounts(liveTitle, item.name)
        if type(counterNeed) == "number" and counterNeed > 0 then need = counterNeed end
        if completable or finished or (type(have) == "number" and have >= need) then
            have = need
        end
        table.insert(requirements.items, {
            name = ItemName(database, language, item.name),
            have = have,
            need = need,
        })
        index = index + 1
    end
    if requiredMoney > 0 then
        requirements.money = {
            text = UQ.L("DIALOGUE_REQUIRED_MONEY") .. "  " .. MoneyText(requiredMoney),
        }
    end
    return requirements
end

-- The required items as plain lines under the progress text, the way the
-- quest log words them: "Prowler Claws: 4/7", or "Prowler Claws x7" when no
-- log counter names the item, then the required money. `separator` joins
-- them on one line instead (the objectives line of a card without a body).
local function RequirementText(requirements, separator)
    if not requirements then return nil end
    local lines = {}
    local index = 1
    while index <= table.getn(requirements.items) do
        local item = requirements.items[index]
        if type(item.have) == "number" then
            table.insert(lines, UQ.L("DIALOGUE_REQUIRED_ITEM_COUNT",
                item.name, item.have, item.need))
        else
            table.insert(lines, UQ.L("DIALOGUE_REQUIRED_ITEM_NEED", item.name, item.need))
        end
        index = index + 1
    end
    if requirements.money then table.insert(lines, requirements.money.text) end
    if table.getn(lines) == 0 then return nil end
    return table.concat(lines, separator or "\n")
end

-- The turn-in panel under the progress page: whether the quest can be handed
-- in, and what handing it in pays. The client's quest-giver reward calls
-- only answer on the completion page, so the items and money come from the
-- quest's own log entry (Client.ReadQuestLogRewards, read once per visit),
-- and experience and reputation from the bundled data, as the completion
-- page shows them (QuestLogRewards:GetGiverLines).
-- Experience and reputation on one line (user request), from the bundled
-- data as the completion page shows them (QuestLogRewards:GetGiverLines).
-- `valued`: each line with only its amount in white (its valueText), for
-- the reward line, which draws the labels in its own dimmer ink.
local function GiverSummaryParts(valued)
    local rewardSummary = UQ:GetModule("QuestLogRewards")
    local lines = rewardSummary and rewardSummary.GetGiverLines
        and rewardSummary:GetGiverLines() or nil
    if not lines or table.getn(lines) == 0 then return nil end
    local parts = {}
    local index = 1
    while index <= table.getn(lines) do
        local line = lines[index]
        table.insert(parts, valued and line.valueText or line.text)
        index = index + 1
    end
    return parts
end

local function GiverSummaryLine()
    local parts = GiverSummaryParts()
    if not parts then return nil end
    return table.concat(parts, "     ")
end

-- The key name a theme with button hints (Minimal) draws after the action
-- button's label, beside Decline's "Esc": only while Space drives the card
-- (option dialogueKeyboard), so the hint never names a dead key.
local function SpaceHint()
    local config = UQ:GetModule("Config")
    if config and config:Get("dialogueKeyboard") == false then return nil end
    return UQ.L("DIALOGUE_KEY_SPACE")
end

-- The one-line reward summary of a card with a rewardLine (the Minimal
-- quest card): the money, then experience and reputation, from the panel
-- BuildRewardPanel or BuildTurnIn made. nil when it pays neither.
-- Returns the line, the money in copper, and the rest of the line after
-- the money: with money, the line is only its "Rewards:" label, since the
-- card draws the amount as coins after it and the rest after the coins
-- (Client.RenderQuestDialogueRewardLine).
local function RewardLine(turnIn)
    if not turnIn then return nil end
    local parts = {}
    local money = type(turnIn.money) == "number" and turnIn.money > 0
        and turnIn.money or nil
    local index = 1
    -- Experience and reputation with only their amounts in white, the labels
    -- in the line's own grey (user request, 2026-10-12).
    local summary = turnIn.summaryValueParts or turnIn.summaryParts
    while summary and index <= table.getn(summary) do
        table.insert(parts, summary[index])
        index = index + 1
    end
    if table.getn(parts) == 0 and not money then return nil end
    -- The separator is "||", the escaped pipe: a lone "|" drew nothing in
    -- game, taken as the start of an escape (user report, 2026-10-12).
    local separator = UQ.L("DIALOGUE_REWARD_SEPARATOR")
    local body = table.concat(parts, separator)
    -- The "Rewards:" label in white (user request, 2026-10-12): the line's
    -- own format, split where its value goes, so every language keeps its
    -- own wording and spacing around it.
    local marked = UQ.L("DIALOGUE_REWARD_LINE", "")
    local at = string.find(marked, "", 1, true)
    if not at and not money then return UQ.L("DIALOGUE_REWARD_LINE", body) end
    local before = at and string.sub(marked, 1, at - 1) or marked
    local after = at and string.sub(marked, at + 1) or ""
    if money then before = string.gsub(before, "%s+$", "") end
    if before ~= "" then before = "|cffffffff" .. before .. "|r" end
    if not money then return before .. body .. after end
    if body ~= "" then body = separator .. body end
    return before, money, body .. after
end

-- The same panel with the money and summary lines taken out, which the
-- reward line now carries, and no header: only its item tiles are left, or
-- nil when it has none.
local function BareTurnIn(turnIn)
    if not turnIn then return nil end
    if table.getn(turnIn.choices or {}) + table.getn(turnIn.rewards or {}) == 0 then
        return nil
    end
    return { bare = true, completable = turnIn.completable, logIndex = turnIn.logIndex,
        choices = turnIn.choices, rewards = turnIn.rewards, lines = {} }
end

local function BuildTurnIn(liveTitle, database, language, completable)
    local questState = UQ:GetModule("QuestState")
    local quest = questState and questState:GetQuestByTitle(liveTitle)
    local logIndex = quest and quest.index or nil
    local cacheKey = tostring(liveTitle) .. "\031" .. tostring(logIndex)
    if Dialogue.turnInKey ~= cacheKey then
        Dialogue.turnInKey = cacheKey
        Dialogue.turnInRewards = Client.ReadQuestLogRewards(logIndex)
    end
    local read = Dialogue.turnInRewards or {}
    local turnIn = { completable = completable and true or false,
        logIndex = logIndex, choices = {}, rewards = {}, lines = {} }
    local function Copy(source, target)
        local index = 1
        while source and index <= table.getn(source) do
            local item = source[index]
            table.insert(target, {
                name = ItemName(database, language, item.name),
                texture = item.texture, count = item.count,
                kind = item.kind, index = item.index,
            })
            index = index + 1
        end
    end
    Copy(read.choices, turnIn.choices)
    Copy(read.rewards, turnIn.rewards)
    if type(read.money) == "number" and read.money > 0 then
        turnIn.money = read.money
        table.insert(turnIn.lines, MoneyLine(read.money,
            table.getn(turnIn.choices) + table.getn(turnIn.rewards) > 0))
    end
    turnIn.summaryParts = GiverSummaryParts()
    turnIn.summaryValueParts = GiverSummaryParts(true)
    local summary = GiverSummaryLine()
    if summary then table.insert(turnIn.lines, summary) end
    return turnIn
end

-- The parchment rewards panel under the card on the accept and completion
-- pages, the same panel the progress page uses (Client.RenderQuestDialogueTurnIn)
-- headed "Rewards": choose-one tiles carrying GearAdvisor's arrow and
-- best-value coin, the guaranteed items, then money, experience and
-- reputation. On the completion page a choice tile selects that reward.
local function BuildRewardPanel(database, language, choices, rewards, marks,
    selectable, selectedChoice)
    local panel = { title = UQ.L("DIALOGUE_REWARDS"), choices = {}, rewards = {},
        lines = {} }
    local function Copy(source, target, kind, withMarks)
        local index = 1
        while index <= table.getn(source) do
            local item = source[index]
            local tile = {
                name = ItemName(database, language, item.name),
                texture = item.texture, count = item.count,
                usable = item.usable,
                tooltipType = kind, index = item.index,
                advisor = withMarks and marks and marks[index] or nil,
            }
            if selectable and kind == "choice" then
                tile.payload = { kind = "rewardChoice", index = item.index }
                tile.selected = selectedChoice == item.index
            end
            table.insert(target, tile)
            index = index + 1
        end
    end
    Copy(choices, panel.choices, "choice", true)
    Copy(rewards, panel.rewards, "reward", false)
    local spell = Client.GetQuestDialogueRewardSpell()
    if spell then
        table.insert(panel.rewards, { name = UQ.L("DIALOGUE_SPELL_REWARD"),
            texture = spell, tooltipType = "spell", index = 0 })
    end
    local money = Client.GetQuestDialogueRewardMoney()
    if money > 0 then
        panel.money = money
        table.insert(panel.lines, MoneyLine(money,
            table.getn(panel.choices) + table.getn(panel.rewards) > 0))
    end
    panel.summaryParts = GiverSummaryParts()
    panel.summaryValueParts = GiverSummaryParts(true)
    local summary = GiverSummaryLine()
    if summary then table.insert(panel.lines, summary) end
    if table.getn(panel.choices) + table.getn(panel.rewards)
        + table.getn(panel.lines) == 0 then
        return nil
    end
    return panel
end

local function TurnInSignature(turnIn)
    if not turnIn then return "" end
    local parts = { turnIn.completable and "C" or "-", tostring(turnIn.title) }
    local function Add(items)
        local index = 1
        while index <= table.getn(items) do
            local item = items[index]
            table.insert(parts, tostring(item.name) .. "x" .. tostring(item.count)
                .. (item.selected and "*" or "")
                .. (item.advisor and (tostring(item.advisor.arrow)
                    .. (item.advisor.coin and "$" or "")) or ""))
            index = index + 1
        end
    end
    Add(turnIn.choices)
    Add(turnIn.rewards)
    local index = 1
    while index <= table.getn(turnIn.lines) do
        local line = turnIn.lines[index]
        -- The money line is { text, money } (MoneyLine).
        if type(line) == "table" then
            line = tostring(line.text) .. "$" .. tostring(line.money)
        end
        table.insert(parts, line)
        index = index + 1
    end
    return table.concat(parts, "|")
end

local function RowsSignature(rows)
    local parts = {}
    local index = 1
    while index <= table.getn(rows) do
        local row = rows[index]
        table.insert(parts, tostring(row.text or ""))
        table.insert(parts, row.selected and "1" or "0")
        if row.advisor then
            table.insert(parts, tostring(row.advisor.arrow))
            table.insert(parts, row.advisor.coin and "1" or "0")
        end
        index = index + 1
    end
    return table.concat(parts, "|")
end

local function BuildView(mode)
    local view = {
        mode = mode,
        speaker = Client.GetQuestDialogueSpeaker() or UQ.L("DIALOGUE_NPC"),
        speakerUnit = Client.ResolveQuestDialogueUnit(),
        title = UQ.L("DIALOGUE_CONVERSATION"),
        -- Which of the two frames draws this page: "conversation" (gossip
        -- and greeting) or "quest" (detail, progress, reward). Every theme
        -- lays the two out separately (Client.GetQuestDialogueLayout); set
        -- before ApplyPages, which pages to that card's body box.
        card = "conversation",
        body = "",
        rows = {},
        actions = {},
    }

    if mode == "gossip" then
        local body = ReadSourceText("gossip", Client.GetQuestDialogueGossipText) or ""
        view.interactionKey = "gossip\031" .. view.speaker .. "\031" .. body
        local liveRows = Client.GetQuestDialogueGossipRows()
        -- A quest giver's options drawn as buttons in the card (a theme's
        -- `optionButtons`, Client.RenderQuestDialogueOptionButtons) stand in
        -- for the NPC's talk, which is then not shown (user request).
        -- Named a quest giver only while it lists a quest, as in
        -- TakesInteraction.
        local questGiver = false
        local scan = 1
        while scan <= table.getn(liveRows) do
            local kind = liveRows[scan].kind
            if kind == "gossipAvailable" or kind == "gossipActive" then questGiver = true end
            scan = scan + 1
        end
        if questGiver then view.speakerRole = UQ.L("DIALOGUE_ROLE_QUEST_GIVER") end
        if questGiver
            and Client.QuestDialogueHasOptionButtons(Dialogue.frame, view.card) then
            view.optionButtons = true
            ApplyPages(view, view.interactionKey .. "\031options", "")
        else
            ApplyPages(view, view.interactionKey, body)
        end
        local index = 1
        while index <= table.getn(liveRows) do
            local live = liveRows[index]
            table.insert(view.rows, {
                text = QuestRowText(live), icon = live.icon, iconAspect = live.iconAspect,
                complete = live.complete, trivial = live.trivial,
                payload = { kind = live.kind, index = live.index },
            })
            index = index + 1
        end
        SetClickActions(view, ListClickAction(view, "closeGossip"))
        if view.hasNextPage then view.rows = {} end
    elseif mode == "greeting" then
        view.speakerRole = UQ.L("DIALOGUE_ROLE_QUEST_GIVER")
        local body = ReadSourceText("greeting", Client.GetQuestDialogueGreetingText) or ""
        view.interactionKey = "greeting\031" .. view.speaker .. "\031" .. body
        local liveRows = Client.GetQuestDialogueGreetingRows()
        -- Every greeting comes from a quest giver: its quests stand in for
        -- the talk on a card that draws them as buttons, as on gossip.
        if table.getn(liveRows) > 0
            and Client.QuestDialogueHasOptionButtons(Dialogue.frame, view.card) then
            view.optionButtons = true
            ApplyPages(view, view.interactionKey .. "\031options", "")
        else
            ApplyPages(view, view.interactionKey, body)
        end
        local index = 1
        while index <= table.getn(liveRows) do
            local live = liveRows[index]
            table.insert(view.rows, {
                text = QuestRowText(live), icon = live.icon, iconAspect = live.iconAspect,
                complete = live.complete,
                payload = { kind = live.kind, index = live.index },
            })
            index = index + 1
        end
        SetClickActions(view, ListClickAction(view, "closeQuest"))
        if view.hasNextPage then view.rows = {} end
    else
        local liveTitle = Client.GetQuestGiverTitle() or ""
        local quest, database, language = QuestContext(liveTitle)
        view.card = "quest"
        view.title = QuestText(database, quest, "T", liveTitle) or liveTitle
        view.quest = quest
        view.speakerRole = UQ.L("DIALOGUE_ROLE_QUEST_GIVER")
        view.kicker = UQ.L("DIALOGUE_KICKER_QUEST")
        -- The kicker's badge: "!" on a quest to accept, "?" on one to turn in.
        view.kickerTurnIn = mode ~= "detail"
        -- A quest card without a body (Minimal) shows no quest text at all:
        -- the page is the objectives line, the rewards and the buttons.
        local bodyless = not Client.QuestDialogueShowsBody(Dialogue.frame, view.card)
        -- Its second button (Client.RenderQuestDialogueSecondaryButton):
        -- Decline on a quest offered, Cancel on one being handed in. Escape
        -- does the same, so the button names the key.
        view.secondaryButton = { action = mode == "detail" and "decline" or "closeQuest",
            text = UQ.L(mode == "detail" and "DIALOGUE_BUTTON_DECLINE" or "DIALOGUE_BUTTON_CANCEL"),
            hint = UQ.L("DIALOGUE_KEY_ESCAPE") }

        if mode == "detail" then
            local nativeBody = ReadSourceText("detailBody", Client.GetQuestGiverDescription)
            local nativeObjective = ReadSourceText("detailObjective", Client.GetQuestGiverObjective)
            local body = QuestText(database, quest, "D", nativeBody) or ""
            -- Without its blank lines in every theme, the strip's or the
            -- body's (CompactLines).
            local objective = CompactLines(QuestText(database, quest, "O", nativeObjective))
            view.objective = objective
            -- A theme with an objectives strip shows it there on every page;
            -- otherwise it reads on at the end of the text.
            if objective and not Client.QuestDialogueHasObjectiveStrip(Dialogue.frame, view.card) then
                body = AppendText(body, UQ.L("DIALOGUE_OBJECTIVES") .. "\n" .. objective)
            end
            if bodyless then body = "" end
            view.interactionKey = "detail\031" .. view.speaker .. "\031"
                .. liveTitle .. "\031" .. tostring(nativeBody or "") .. "\031"
                .. tostring(nativeObjective or "")
            ApplyPages(view, view.interactionKey .. "\031" .. body, body)
            local choices = Client.GetQuestDialogueItems("choice")
            local gear = UQ:GetModule("GearAdvisor")
            local marks = gear and gear.GetDialogueMarks
                and gear:GetDialogueMarks(choices) or nil
            view.turnIn = BuildRewardPanel(database, language, choices,
                Client.GetQuestDialogueItems("reward"), marks, false, 0)
            SetClickActions(view, "accept")
            -- A theme's action button on the card's bottom band
            -- (Client.RenderQuestDialogueActionButton).
            view.actionButton = { action = "accept",
                text = UQ.L("DIALOGUE_BUTTON_ACCEPT"),
                shortText = UQ.L("DIALOGUE_BUTTON_ACCEPT_SHORT"),
                hint = SpaceHint() }
        elseif mode == "progress" then
            local nativeBody = ReadSourceText("progress",
                Client.GetQuestDialogueProgressText) or ""
            -- The client reads the objective only on the detail page; here
            -- it comes from the world data, when the quest is matched.
            view.objective = QuestText(database, quest, "O", nil)
            view.interactionKey = "progress\031" .. view.speaker .. "\031"
                .. liveTitle .. "\031" .. nativeBody
            -- The required items read as part of the card's text, under what
            -- the NPC says; the panel below holds the status and the rewards.
            local completable = Client.IsQuestDialogueCompletable()
            local requirements = BuildRequirements(liveTitle, database, language, completable)
            local body = AppendText(nativeBody, RequirementText(requirements))
            if bodyless then
                -- Without a body the counts are the objectives line: every
                -- objective as the log counts it (kills too), else the items.
                body = ""
                view.objective = LogObjectiveText(liveTitle, ", ")
                    or RequirementText(requirements, ", ") or view.objective
            end
            ApplyPages(view, view.interactionKey .. "\031" .. body, body)
            view.turnIn = BuildTurnIn(liveTitle, database, language, completable)
            -- Immersion hands in a completable quest and otherwise closes.
            SetClickActions(view, completable and "progress" or "closeQuest")
            -- Disabled until every objective is done.
            view.actionButton = { action = "progress",
                text = UQ.L("DIALOGUE_BUTTON_COMPLETE"),
                shortText = UQ.L("DIALOGUE_BUTTON_COMPLETE_SHORT"),
                enabled = completable and true or false,
                hint = SpaceHint() }
        elseif mode == "reward" then
            local nativeBody = ReadSourceText("reward", Client.GetQuestCompletionText)
            local body = QuestText(database, quest, "D", nativeBody) or ""
            if bodyless then body = "" end
            -- The objectives as done, with their counts ("10/10") while the
            -- quest is still in the log (user request); else the quest's text.
            view.objective = LogObjectiveText(liveTitle, bodyless and ", " or "\n")
                or QuestText(database, quest, "O", nil)
            view.interactionKey = "reward\031" .. view.speaker .. "\031"
                .. liveTitle .. "\031" .. tostring(nativeBody or "")
            ApplyPages(view, view.interactionKey .. "\031" .. body, body)
            local choices = Client.GetQuestDialogueItems("choice")
            local rewards = Client.GetQuestDialogueItems("reward")
            local gear = UQ:GetModule("GearAdvisor")
            local marks = gear and gear.GetDialogueMarks
                and gear:GetDialogueMarks(choices) or nil
            view.turnIn = BuildRewardPanel(database, language, choices, rewards,
                marks, true, Dialogue.selectedChoice)
            local spell = Client.GetQuestDialogueRewardSpell()

            local inspectorCards = {}
            local index = 1
            while index <= table.getn(choices) do
                table.insert(inspectorCards, ItemRow(choices[index], true,
                    Dialogue.selectedChoice, database, language,
                    marks and marks[index] or nil))
                index = index + 1
            end
            index = 1
            while index <= table.getn(rewards) do
                table.insert(inspectorCards, ItemRow(rewards[index], false, 0,
                    database, language, nil))
                index = index + 1
            end
            if spell then
                table.insert(inspectorCards, {
                    text = UQ.L("DIALOGUE_SPELL_REWARD"), icon = spell,
                    rewardType = "spell", rewardIndex = 0, enabled = false,
                    payload = { kind = "spell" },
                })
            end
            local totalCards = table.getn(inspectorCards)
            local pageCount = math.ceil(totalCards / INSPECTOR_PAGE_SIZE)
            if pageCount < 1 then pageCount = 1 end
            if Dialogue.inspectorPage < 1 then Dialogue.inspectorPage = 1 end
            if Dialogue.inspectorPage > pageCount then Dialogue.inspectorPage = pageCount end
            view.inspectorPageIndex = Dialogue.inspectorPage
            view.inspectorPageCount = pageCount
            view.inspectorCards = {}
            local firstCard = (Dialogue.inspectorPage - 1) * INSPECTOR_PAGE_SIZE + 1
            local lastCard = firstCard + INSPECTOR_PAGE_SIZE - 1
            if lastCard > totalCards then lastCard = totalCards end
            index = firstCard
            while index <= lastCard do
                table.insert(view.inspectorCards, inspectorCards[index])
                index = index + 1
            end
            view.showInspector = Dialogue.inspectorOpen and not view.hasNextPage
                and totalCards > 0
            view.inspectorActions = {
                { id = "closeInspector", text = UQ.L("DIALOGUE_BACK") },
            }
            if pageCount > 1 and Dialogue.inspectorPage > 1 then
                table.insert(view.inspectorActions, {
                    id = "previousInspectorPage", text = UQ.L("DIALOGUE_BACK") })
            end
            if pageCount > 1 and Dialogue.inspectorPage < pageCount then
                table.insert(view.inspectorActions, {
                    id = "nextInspectorPage", text = UQ.L("DIALOGUE_CONTINUE") })
            end
            table.insert(view.inspectorActions, {
                id = "reward", text = UQ.L("DIALOGUE_COMPLETE") })
            SetClickActions(view, "reward")
            -- Handing the quest in takes the Complete button or Space, never
            -- a click elsewhere on the card: a stray click after picking a
            -- reward completed the quest (user report, 2026-10-12). Such a
            -- click only finishes the text.
            if view.clickAction == "reward" then
                view.clickAction = "revealText"
                view.keyAction = "reward"
            end
            view.actionButton = { action = "reward",
                text = UQ.L("DIALOGUE_BUTTON_COMPLETE"),
                shortText = UQ.L("DIALOGUE_BUTTON_COMPLETE_SHORT"),
                hint = SpaceHint() }
            if table.getn(view.inspectorCards) == 0
                and view.rightClickAction == "inspectRewards" then
                view.rightClickAction = nil
            end
        end
        -- A bodyless card has no text to page or finish, so a click on it
        -- does nothing: taking the page's step there handed the quest in and
        -- re-laid the card under the cursor (user report, 2026-10-12). The
        -- step stays on Space and the action button.
        if bodyless and view.clickAction ~= "nextPage" then
            view.keyAction = view.keyAction or view.clickAction
            view.clickAction = "revealText"
        end
        -- A card with a reward line reads the money, experience and
        -- reputation there; the panel under it keeps only the item tiles.
        if Client.QuestDialogueHasRewardLine(Dialogue.frame, view.card) then
            view.rewardLine, view.rewardMoney, view.rewardLineTail = RewardLine(view.turnIn)
            view.turnIn = BareTurnIn(view.turnIn)
        end
        -- The strip shows the objective without blank lines, and a card
        -- that grows with it is told how many lines it then wraps to
        -- (Client.QuestDialogueObjectiveGrow).
        view.objective = CompactLines(view.objective)
        local objectiveColumns = Client.GetQuestDialogueObjectiveColumns(Dialogue.frame, view.card)
        if objectiveColumns and type(view.objective) == "string" and view.objective ~= "" then
            view.objectiveLines = CountLines(view.objective, objectiveColumns)
        end
    end
    view.rowsSignature = RowsSignature(view.rows)
    return view
end

local function ViewSignature(mode, view)
    local parts = { mode or "", view.speaker or "", view.title or "",
        view.body or "", view.objective or "",
        tostring(view.pageIndex or 1), tostring(view.pageCount or 1),
        view.rowsSignature or "", view.showInspector and "I" or "-",
        tostring(view.inspectorPageIndex or 1), tostring(view.inspectorPageCount or 1),
        tostring(view.clickAction or ""), tostring(view.rightClickAction or ""),
        tostring(view.keyAction or ""), TurnInSignature(view.turnIn), view.rewardLine or "",
        tostring(view.rewardMoney or ""), view.rewardLineTail or "",
        view.actionButton and (tostring(view.actionButton.action) .. ":"
            .. tostring(view.actionButton.enabled ~= false) .. ":"
            .. tostring(view.actionButton.hint)) or "",
        view.secondaryButton and tostring(view.secondaryButton.action) or "" }
    return table.concat(parts, "\031")
end

-- Losing the NPC ends the conversation. On this client the speaker is
-- usually the target ("npc" resolves to nothing, see
-- Client.ResolveQuestDialogueUnit), so the dialogue remembers the target it
-- opened on; when the player clears it (a left click on empty ground) or
-- picks another, the interaction is closed as if they had walked away.
-- Polled on the dialogue's own driver job, like everything else here; a
-- dialogue that opened without a target (an object quest giver) is never
-- armed. Returns true when it closed the dialogue.
function Dialogue:CheckSpeakerFocus(view)
    local name = Client.UnitExists("target") and Client.GetUnitName("target") or nil
    if not self.focusName then
        if view.speakerUnit == "target" and name then self.focusName = name end
        return false
    end
    if name == self.focusName then return false end
    self:CloseConversation()
    return true
end

-- Ends the NPC interaction from the player's side: losing the NPC target,
-- or Escape (see CloseOnGameMenu).
function Dialogue:CloseConversation()
    self.focusName = nil
    self:RunAction(self.mode == "gossip" and "closeGossip" or "closeQuest", false)
end

-- Escape hid the card through the client's Escape list
-- (Client.SetQuestDialogueEscape): end the conversation exactly as losing
-- the NPC does, and remember when, so the game menu that same press may open
-- is put away too.
function Dialogue:OnEscape()
    if not self.mode then return end
    self.escapedAt = Client.Now()
    self:CloseConversation()
end

-- The game menu up together with the card, or just after Escape closed it,
-- is the Escape that closed the conversation: close it if still open and put
-- the menu away. Polled on the dialogue's own driver job, never hooked on the
-- menu (see Client.IsGameMenuShown). Returns true when it closed the
-- dialogue; with no dialogue open the menu is left alone.
function Dialogue:CloseOnGameMenu()
    local cardUp = self.mode and Client.IsObjectShown(self.frame)
    local now = Client.Now()
    local escaped = self.escapedAt and now
        and now - self.escapedAt <= ESCAPE_MENU_WINDOW
    if not cardUp and not escaped then
        self.escapedAt = nil
        return false
    end
    if not Client.IsGameMenuShown() then return false end
    self.escapedAt = nil
    Client.HideGameMenu()
    if not cardUp then return false end
    self:CloseConversation()
    return true
end

function Dialogue:Hide(restoreNative)
    self.focusName = nil
    self.turnInKey = nil
    self.turnInRewards = nil
    self.backdropFor = nil
    Client.HideQuestDialogue(self.frame)
    Client.SetNativeQuestDialogueSuppressed("gossip", false,
        restoreNative and self.lastNativeKind == "gossip")
    Client.SetNativeQuestDialogueSuppressed("quest", false,
        restoreNative and self.lastNativeKind == "quest")
    self.mode = nil
    self.lastSignature = nil
    self.lastNativeKind = nil
    self.pageKey = nil
    self.pages = nil
    self.pageIndex = 1
    self.inspectorOpen = nil
    self.inspectorPage = 1
    self.interactionKey = nil
    self.sourceText = {}
    self.revealKey = nil
    self.revealCharacters = nil
    self.revealCount = 0
    self.revealNextAt = nil
    self.revealing = nil
    local flags = UQ:GetModule("QuestLanguageFlags")
    if flags then flags:Hide("dialogue") end
end

-- Hides the HUD while the card is up and brings it back once it is gone
-- (option dialogueHideInterface, Client.SetGameInterfaceHidden; the tracker
-- and the combined world tooltip through their own SetSuppressed, so their
-- own redraw does not show them again). Run after every Refresh rather than from Show/Hide, so a frame its
-- owner showed again is hidden again and turning the option off
-- mid-conversation brings the HUD straight back.
-- Option dialogueKeyboard (default on): Space and Escape drive the card,
-- every other key waits until it closes (Client.CreateQuestDialogueKeyCatcher).
local function KeyboardWanted()
    local config = UQ:GetModule("Config")
    return not config or config:Get("dialogueKeyboard") ~= false
end

-- Space comes off its binding (Jump) while the catcher holds the keyboard:
-- the catcher sees Space, but on this client the character jumped all the
-- same (Client.GetKeyBindingAction). The command is kept in the config until
-- it is given back, which is only onto a Space still left unbound -- a key
-- the player rebound meanwhile stays theirs.
local function HoldSpaceBinding(held)
    local config = UQ:GetModule("Config")
    if not config then return end
    local saved = config:Get("dialogueSpaceBinding")
    if held then
        if saved then return end
        local action = Client.GetKeyBindingAction("SPACE")
        if action and Client.SetKeyBinding("SPACE", nil) then
            config:Set("dialogueSpaceBinding", action)
        end
    elseif saved then
        if not Client.GetKeyBindingAction("SPACE") then
            Client.SetKeyBinding("SPACE", saved)
        end
        config:Set("dialogueSpaceBinding", false)
    end
end

-- The key catcher holds the keyboard exactly while the card is up; the
-- card's OnHide also lets go at once. Space's binding comes back on the
-- poll after the card closes, so never inside the press that closed it.
function Dialogue:SyncKeyboard()
    local wanted = KeyboardWanted() and self.mode ~= nil
        and Client.IsObjectShown(self.frame)
    Client.SetQuestDialogueKeyboard(self.frame, wanted)
    HoldSpaceBinding(wanted)
end

function Dialogue:SyncInterfaceHidden()
    local config = UQ:GetModule("Config")
    local wanted = not config or config:Get("dialogueHideInterface") ~= false
    local hidden = wanted and self.mode ~= nil and Client.IsObjectShown(self.frame)
    Client.SetGameInterfaceHidden(hidden)
    local tracker = UQ:GetModule("TrackerFrame")
    if tracker and tracker.SetSuppressed then tracker:SetSuppressed(hidden) end
    local entity = UQ:GetModule("EntityTooltip")
    if entity and entity.SetSuppressed then entity:SetSuppressed(hidden) end
end

function Dialogue:FinishTextReveal()
    if not self.revealing
        and not Client.IsQuestDialogueLetterAnimationActive(self.frame) then
        return false
    end
    local characters = self.revealCharacters or {}
    self.revealCount = table.getn(characters)
    self.revealNextAt = nil
    self.revealing = nil
    if self.lastView then
        self.lastView.revealCount = self.revealCount
        self.lastView.bodyRevealing = false
    end
    Client.FinishQuestDialogueLetters(self.frame)
    return true
end

function Dialogue:StepTextReveal(now)
    if not self.revealing or type(now) ~= "number" then return false end
    local characters = self.revealCharacters or {}
    local total = table.getn(characters)
    local count = self.revealCount or 0
    local nextAt = self.revealNextAt or now
    local changed = false
    while now >= nextAt do
        if count < total then
            count = count + 1
            Client.RevealQuestDialogueLetter(self.frame, count, nextAt)
            nextAt = nextAt + RevealDelay(characters[count])
            changed = true
        else
            break
        end
    end
    if not changed then return false end
    self.revealCount = count
    self.revealNextAt = nextAt
    local finished = count >= total
    if finished then
        self.revealing = nil
        self.revealNextAt = nil
    end
    if self.lastView then
        self.lastView.revealCount = count
        self.lastView.bodyRevealing = not finished
    end
    return true
end

function Dialogue:SelectRow(payload)
    if type(payload) ~= "table" then return end
    if payload.kind == "rewardChoice" then
        self.selectedChoice = payload.index or 0
        self.lastSignature = nil
        self:Refresh()
        return
    end
    if payload.kind == "gossipOption" or payload.kind == "gossipAvailable"
        or payload.kind == "gossipActive" or payload.kind == "available"
        or payload.kind == "active" then
        Client.RunQuestDialogueAction(payload.kind, payload.index)
        -- The page a row opens arrives with the server's answer, many frames
        -- later. Read without a hint meanwhile, the last quest's lingering
        -- title and reward text made the card a turn-in at once: stale
        -- rewards drawn, and the gossip root disarmed and left on screen
        -- until it closed (questflash.v1, 2026-10-12). The current page holds
        -- until a page event, a stock root opening, or ROW_ANSWER_WAIT.
        self.rowPending = { mode = self.mode, untilTime = Client.Now() + ROW_ANSWER_WAIT }
        self.modeHint = nil
        self.lastSignature = nil
    end
end

function Dialogue:RunAction(action, fromClick)
    if fromClick and self:FinishTextReveal() then
        return
    elseif action == "selectRow" then
        local view = self.lastView
        if view and view.clickPayload then self:SelectRow(view.clickPayload) end
    elseif action == "firstPage" then
        self.pageIndex = 1
        self.lastSignature = nil
        self:Refresh()
    elseif action == "nextPage" then
        self.pageIndex = self.pageIndex + 1
        self.lastSignature = nil
        self:Refresh()
    elseif action == "previousPage" then
        self.pageIndex = self.pageIndex - 1
        self.lastSignature = nil
        self:Refresh()
    elseif action == "inspectRewards" then
        self.inspectorOpen = true
        self.lastSignature = nil
        self:Refresh()
    elseif action == "closeInspector" then
        self.inspectorOpen = nil
        Client.HideQuestDialogueInspector(self.frame)
        self.lastSignature = nil
        self:Refresh()
    elseif action == "nextInspectorPage" then
        self.inspectorPage = self.inspectorPage + 1
        self.lastSignature = nil
        self:Refresh()
    elseif action == "previousInspectorPage" then
        self.inspectorPage = self.inspectorPage - 1
        self.lastSignature = nil
        self:Refresh()
    elseif action == "reward" then
        local choices = Client.GetQuestDialogueItems("choice")
        if table.getn(choices) > 1 and self.selectedChoice < 1 then
            self.inspectorOpen = true
            self.lastSignature = nil
            self:Refresh()
            Client.ShowQuestDialogueChoiceRequired(self.frame)
            return
        end
        local index = self.selectedChoice
        if table.getn(choices) == 1 and index < 1 then index = 1 end
        Client.RunQuestDialogueAction("reward", index)
        self.closed = true
        self.modeHint = nil
        self:Hide(false)
    elseif action == "accept" or action == "decline"
        or action == "closeGossip" or action == "closeQuest" then
        Client.RunQuestDialogueAction(action)
        self.closed = true
        self.modeHint = nil
        self:Hide(false)
    elseif action == "progress" and Client.IsQuestDialogueCompletable() then
        Client.RunQuestDialogueAction("progress")
        self.modeHint = nil
        self.lastSignature = nil
    end
end

-- Option dialogueAutoQuest (default off): accepts an offered quest, hands in a
-- completable one and takes its reward -- unless that reward is a choice
-- between several items, which stays with the player. Each page is acted on
-- once (autoKey: page, stock-root generation, quest title), because the quest
-- text stays readable after the page's own action and the next poll would
-- otherwise repeat it. Returns true when it acted.
function Dialogue:AutoAdvance(mode)
    local config = UQ:GetModule("Config")
    if not config or config:Get("dialogueAutoQuest") ~= true then return false end
    local action
    if mode == "detail" then
        action = "accept"
    elseif mode == "progress" then
        if not Client.IsQuestDialogueCompletable() then return false end
        action = "progress"
    elseif mode == "reward" then
        if table.getn(Client.GetQuestDialogueItems("choice")) > 1 then return false end
        action = "reward"
    else
        return false
    end
    local key = mode .. "|" .. tostring(self.questSignal) .. "|"
        .. tostring(Client.GetQuestGiverTitle())
    if self.autoKey == key then return false end
    self.autoKey = key
    self:RunAction(action, false)
    return true
end

function Dialogue:Refresh()
    Client.InstallQuestDialogueGuards()
    local questSignal, gossipSignal = Client.GetQuestDialogueSignal()
    local signalChanged = questSignal ~= self.questSignal or gossipSignal ~= self.gossipSignal
    -- Only a stock root showing (its generation or shown flag rising) is a
    -- new interaction. A root hiding is the end of one: the quest text stays
    -- readable after CloseQuest, so treating that as new reopened the card
    -- after Escape (user report, 2026-10-06).
    local opened = (questSignal or 0) > (self.questSignal or 0)
        or (gossipSignal or 0) > (self.gossipSignal or 0)
    self.questSignal = questSignal
    self.gossipSignal = gossipSignal
    if signalChanged then self.sourceText = {} end

    if not Enabled() then
        self.closed = nil
        self.modeHint = nil
        self:Hide(true)
        return
    end
    if self:CloseOnGameMenu() then return end
    -- A theme switch changes the body box, so the text is paged afresh and
    -- the card is rescaled and redrawn on the new art.
    if Client.SetQuestDialogueTheme(self.frame, Theme()) then
        self.pageKey = nil
        self.revealKey = nil
        self.lastSignature = nil
    end

    -- A stock root closing ends the conversation unless the other root took
    -- it over: a gossip row that opens a quest closes the gossip as the quest
    -- page shows (and a quest page handed back to gossip the other way).
    -- Closing on the event itself dropped the card between the two pages and
    -- redrew it on the next poll (flicker, user report, 2026-10-12).
    if self.closePending then
        local takenOver = Client.IsQuestDialogueRootShown(self.closePending)
        self.closePending = nil
        if not takenOver then
            self.modeHint = nil
            self.closed = true
            self.selectedChoice = 0
            self:Hide(false)
            return
        end
    end

    -- A row's answer still on its way keeps the page the row was on (see
    -- SelectRow); the timeout is the poll's fallback when no event comes.
    local hint = self.modeHint
    local pending = self.rowPending
    if pending then
        if opened or not pending.mode or Client.Now() >= pending.untilTime then
            self.rowPending = nil
        elseif not hint then
            hint = pending.mode
        end
    end
    local mode, sourceKey, sourceValue = Client.ResolveQuestDialogueMode(
        hint, self.sourceText)
    if self.closed and not opened then
        if not mode then self.closed = nil end
        self:Hide(false)
        return
    end
    if opened then self.closed = nil end
    if not mode then
        self.modeHint = nil
        self.selectedChoice = 0
        self:Hide(false)
        return
    end
    -- After the closed check, so a page whose action already closed the
    -- conversation is not acted on again from its lingering text.
    if self:AutoAdvance(mode) then return end
    if not TakesInteraction(mode, self.mode ~= nil) then
        if self.lastNativeKind then self:Hide(true) end
        -- The OnShow guard may have concealed this root on a guess the live
        -- rows no longer support; give it back to the stock window.
        Client.SetNativeQuestDialogueSuppressed(
            mode == "gossip" and "gossip" or "quest", false, true)
        return
    end

    if self.mode ~= mode then
        if mode ~= "reward" then self.selectedChoice = 0 end
        self.pageKey = nil
        self.pages = nil
        self.pageIndex = 1
        self.inspectorOpen = nil
        self.inspectorPage = 1
        self.interactionKey = nil
        self.sourceText = {}
        self.revealKey = nil
    end
    if type(sourceKey) == "string" and type(sourceValue) == "string"
        and sourceValue ~= "" then
        self.sourceText[sourceKey] = sourceValue
    end
    self.mode = mode
    local nativeKind = mode == "gossip" and "gossip" or "quest"
    local otherKind = nativeKind == "gossip" and "quest" or "gossip"
    Client.SetNativeQuestDialogueSuppressed(otherKind, false, false)
    Client.SetNativeQuestDialogueSuppressed(nativeKind, true, false)
    self.lastNativeKind = nativeKind

    local view = BuildView(mode)
    if self.interactionKey ~= view.interactionKey then
        self.interactionKey = view.interactionKey
        self.selectedChoice = 0
        self.inspectorPage = 1
        self.inspectorOpen = nil
        view = BuildView(mode)
    end
    PrepareTextReveal(view)
    if self:CheckSpeakerFocus(view) then return end
    self.lastView = view
    local signature = ViewSignature(mode, view)
    if signature ~= self.lastSignature then
        self.lastSignature = signature
        Client.RenderQuestDialogue(self.frame, view,
            function(payload) Dialogue:SelectRow(payload) end,
            -- `direct`: the action button, which acts at once rather than
            -- first finishing the text reveal as a click on the card does.
            function(action, direct) Dialogue:RunAction(action, not direct) end)
    else
        Client.ShowObject(self.frame)
        -- Rides this poll for its retry budget; see SetQuestDialoguePortrait.
        Client.SetQuestDialoguePortrait(self.frame, view.speakerUnit, view.speaker)
    end
    local backdropFor = view.quest and view.quest.questId or false
    if self.backdropFor ~= backdropFor then
        self.backdropFor = backdropFor
        self.backdrop = ResolveBackdrop(view.quest and view.quest.questId)
    end
    Client.SetQuestDialogueBackdrop(self.frame, self.backdrop)

    local flags = UQ:GetModule("QuestLanguageFlags")
    local translation = UQ:GetModule("QuestLogTranslation")
    local flagX, flagY = Client.GetQuestDialogueFlagInset(self.frame)
    if flags then
        flags:Refresh({
            key = "dialogue",
            namePrefix = "UnrealQuestDialogueLanguageFlag",
            quest = view.quest,
            anchor = Client.GetQuestDialogueFlagAnchor(self.frame, view.showInspector),
            translation = translation,
            insetX = flagX,
            insetY = flagY,
            framed = Theme() ~= "parchment" and Theme() ~= "minimal",
            theme = Theme(),
            place = function(button, anchor, offsetX, offsetY)
                return Client.PlaceQuestDialogueFlag(button, anchor, offsetX, offsetY)
            end,
            onChanged = function()
                Dialogue.pageKey = nil
                Dialogue.revealKey = nil
                Dialogue.lastSignature = nil
                Dialogue:Refresh()
            end,
        })
    end
    local now = Client.Now()
    self:StepTextReveal(now)
end

function Dialogue:OnDialogueEvent(event)
    if event == "GOSSIP_SHOW" or event == "QUEST_GREETING"
        or event == "QUEST_DETAIL" or event == "QUEST_ACCEPTED"
        or event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
        -- The root a pending close waits for is a takeover; the root that
        -- just closed opening again is a new interaction, closed first.
        local kind = event == "GOSSIP_SHOW" and "gossip" or "quest"
        if self.closePending and self.closePending ~= kind then
            self.selectedChoice = 0
            self:Hide(false)
        end
        self.sourceText = {}
        self.interactionKey = nil
        self.pageKey = nil
        self.pageIndex = 1
        self.inspectorPage = 1
        self.revealKey = nil
        self.closePending = nil
        self.rowPending = nil
        local driver = UQ:GetModule("Driver")
        if driver then driver:Wake("quest.dialogue") end
    end
    if event == "GOSSIP_SHOW" then
        self.modeHint = "gossip"
        self.closed = nil
    elseif event == "QUEST_GREETING" then
        self.modeHint = "greeting"
        self.closed = nil
    elseif event == "QUEST_DETAIL" or event == "QUEST_ACCEPTED" then
        self.modeHint = "detail"
        self.closed = nil
    elseif event == "QUEST_PROGRESS" then
        self.modeHint = "progress"
        self.closed = nil
    elseif event == "QUEST_COMPLETE" then
        self.modeHint = "reward"
        self.closed = nil
    elseif event == "GOSSIP_CLOSED" or event == "QUEST_FINISHED" then
        -- Decided on the next poll (see Refresh): the other root may be
        -- taking the conversation over. The closed root is disarmed now, so
        -- it opening again is judged afresh by the OnShow guard.
        local closedKind = event == "GOSSIP_CLOSED" and "gossip" or "quest"
        Client.SetNativeQuestDialogueSuppressed(closedKind, false, false)
        self.closePending = closedKind == "gossip" and "quest" or "gossip"
        local driver = UQ:GetModule("Driver")
        if driver then driver:Wake("quest.dialogue") end
    end
    self.lastSignature = nil
end

function Dialogue:OnInit()
    Client.ApplyQuestDialogueThemeScale("parchment")
    self.frame = Client.CreateQuestDialogueFrame()
    Client.SetQuestDialogueEscape(self.frame, function() Dialogue:OnEscape() end)
    Client.SetQuestDialogueKeyEscape(self.frame, function() Dialogue:OnEscape() end)
    Client.SetQuestDialogueVoidClick(self.frame, function()
        if Dialogue.mode then Dialogue:CloseConversation() end
    end)
    -- Same answer Refresh reaches, given early so the stock root is concealed
    -- from inside its own OnShow; the card follows on the next driver tick.
    Client.SetQuestDialogueShowDecider(function(kind)
        if not self.frame or not Enabled() then return false end
        -- With a close pending, only the root it waits for continues the
        -- conversation; the closed root showing again is a new one.
        local holding = self.mode ~= nil
            and (not self.closePending or self.closePending == kind)
        local takes = TakesInteraction(kind == "gossip" and "gossip" or "detail",
            holding)
        if takes then
            local driver = UQ:GetModule("Driver")
            if driver then driver:Wake("quest.dialogue") end
        end
        return takes
    end)
    Client.InstallQuestDialogueGuards()
    if self.frame then
        UQ:DeclareCapability("immersiveDialogue", "unverified",
            "Addon-owned gossip, paginated quest text and reward inspector use "
            .. "documented quest APIs plus the shared Driver; the square 3D portrait "
            .. "uses the runtime-tested SetUnit plus SetCamera(0) sequence. The "
            .. "replacement still requires the documented in-game interaction pass")
        UQ:DeclareCapability("questDialogue.keyboard", "unverified",
            "Space advances or accepts and Esc closes through a plain keyboard "
            .. "Frame shown only while the card is up; that frame takes every key "
            .. "(scripts.keyboard_frame_captures_all_input). Option dialogueKeyboard")
        UQ:DeclareCapability("questDialogue.spaceUnbind", "verified",
            "Space still jumped under the key catcher, so while the card is up "
            .. "Space is unbound with SetBinding(key) and its command bound back "
            .. "after (never SaveBindings); user-confirmed to stop the jump "
            .. "(scripts.keyboard_frame_does_not_block_jump)")
        UQ:DeclareCapability("questDialogue.hideInterface", "unverified",
            "Unit frames, bars, minimap, chat, tracker and world tooltip (stock, plus "
            .. "unrealUI's when it is loaded) are hidden with Hide() while the card "
            .. "is up and shown again after; never confirmed in game")
        UQ:DeclareCapability("questDialogue.actionButtonPressed", "unverified",
            "The Alliance V2 action button's pressed face rides OnMouseDown / "
            .. "OnMouseUp on a Button, which have no runtime record on this client; "
            .. "hover, disabled and the click itself do not depend on them")
    else
        UQ:DeclareCapability("immersiveDialogue", "missing",
            "The addon-owned dialogue frame could not be created; stock quest and "
            .. "gossip windows remain available")
    end
end

function Dialogue:OnEnable()
    local events = UQ:GetModule("Events")
    if events then
        local names = {
            "GOSSIP_SHOW", "GOSSIP_CLOSED", "QUEST_GREETING", "QUEST_DETAIL",
            "QUEST_ACCEPTED", "QUEST_PROGRESS", "QUEST_COMPLETE",
            "QUEST_FINISHED", "QUEST_ITEM_UPDATE",
        }
        local index = 1
        while index <= table.getn(names) do
            local event = names[index]
            events:Register(event, function(observed)
                Dialogue:OnDialogueEvent(observed)
            end)
            index = index + 1
        end
    end
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("quest.dialogue", POLL_INTERVAL, function()
            Dialogue:Refresh()
            Dialogue:SyncInterfaceHidden()
            Dialogue:SyncKeyboard()
        end)
        driver:Schedule("quest.dialogue.park", 0, function()
            local now = Client.Now()
            Client.KeepQuestDialogueRootsParked()
            Client.KeepGameInterfaceHidden()
            if Dialogue.revealing then Dialogue:StepTextReveal(now) end
            Client.StepQuestDialogueLetters(Dialogue.frame, now)
            Client.SettleQuestDialogueLabels()
            Client.StepQuestDialogueDim(Dialogue.frame)
            Client.UpdateQuestDialogueAnimation(Dialogue.frame, now)
        end)
    end
end
