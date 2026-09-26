--[[
UnrealQuest / Quest/GearAdvisor.lua

Marks over the choose-one rewards on the quest-giver's completion window: a
green arrow on the reward that improves the player's gear the most, a yellow
one on the runner-up, a red downward arrow on a reward the player can wear
that is no better than what they have on, and a coin on the reward that sells
for the most. See docs/GEAR-ADVISOR.md for the weights and the limits.

Everything is read from tooltip TEXT -- the reward's and the equipped item's --
because this client has no item-stat API and its quest item link is broken
(quest.reward_item_link_nil_after_tooltip_population). Stat lines are matched
through the client's own format globals where it has them (ITEM_MOD_STAMINA,
ARMOR_TEMPLATE, INVTYPE_HEAD ...) with the English text as fallback; the
"Equip:" effects are item spell descriptions with no format global, so those
patterns are English and only an enUS client reads them.

The talent tree with the most points picks the stat weights, by its background
file name, which does not depend on the client language. Sell prices come from
the bundled table through the item name index (Data/Database.lua).

Polled on the shared driver. The work runs once per window state: the offered
names, the equipped item links and the spec form a signature, and the marks
are re-applied from the cached result until it changes.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local GearAdvisor = UQ:NewModule("GearAdvisor")

local POLL_INTERVAL = 0.3
-- An evaluation missing an input (item cache, name index, an unreadable slot)
-- is redone after this many passes rather than on every one.
local RETRY_PASSES = 5

-- Stat weights per spec, in points of the spec's main stat. Percentages (HIT,
-- CRIT ...) are per 1%, MDPS/RDPS per point of weapon damage per second.
local WEIGHTS = {
    WARRIOR_DPS = { STR = 1, AGI = 0.6, STA = 0.5, AP = 0.5, CRIT = 14, HIT = 12,
        MDPS = 4, RDPS = 0.3, ARMOR = 0.02, DEF = 0.2, DODGE = 2, PARRY = 2 },
    WARRIOR_TANK = { STA = 1, AGI = 0.6, STR = 0.5, ARMOR = 0.06, DEF = 1.5,
        DODGE = 14, PARRY = 12, BLOCK = 6, BLOCKVALUE = 0.3, HIT = 4, CRIT = 3,
        AP = 0.15, MDPS = 1.5, RDPS = 0.2, HP5 = 1 },
    PALADIN_DPS = { STR = 1, AGI = 0.5, INT = 0.35, STA = 0.5, SPI = 0.1, AP = 0.5,
        SP = 0.3, SCHOOL_HOLY = 0.3, CRIT = 12, HIT = 10, MDPS = 4, ARMOR = 0.02,
        MP5 = 0.5 },
    PALADIN_TANK = { STA = 1, STR = 0.5, AGI = 0.5, INT = 0.2, ARMOR = 0.06,
        DEF = 1.5, DODGE = 14, PARRY = 12, BLOCK = 6, BLOCKVALUE = 0.4, SP = 0.6,
        SCHOOL_HOLY = 0.6, HIT = 4, MDPS = 1, MP5 = 0.5 },
    PALADIN_HEAL = { HEAL = 1, SP = 1, INT = 0.9, SPI = 0.1, STA = 0.3, MP5 = 1.6,
        SPELLCRIT = 10, ARMOR = 0.01 },
    HUNTER = { AGI = 1, INT = 0.35, STA = 0.5, SPI = 0.1, STR = 0.05, AP = 0.45,
        RAP = 0.45, CRIT = 14, HIT = 14, RDPS = 4, MDPS = 0.4, ARMOR = 0.02,
        MP5 = 0.8 },
    ROGUE = { AGI = 1, STR = 0.5, STA = 0.5, AP = 0.5, CRIT = 14, HIT = 15,
        MDPS = 4, RDPS = 0.3, ARMOR = 0.02, DODGE = 4 },
    PRIEST_HEAL = { HEAL = 1, SP = 1, INT = 0.6, SPI = 0.5, STA = 0.3, MP5 = 1.6,
        SPELLCRIT = 8, RDPS = 0.8, ARMOR = 0.01 },
    PRIEST_DPS = { SP = 1, SCHOOL_SHADOW = 1, INT = 0.4, SPI = 0.3, STA = 0.4,
        SPELLHIT = 10, SPELLCRIT = 6, MP5 = 0.8, RDPS = 1.2, ARMOR = 0.01 },
    SHAMAN_MELEE = { STR = 1, AGI = 0.6, INT = 0.3, STA = 0.5, AP = 0.5, CRIT = 12,
        HIT = 10, MDPS = 4, SP = 0.1, ARMOR = 0.02, MP5 = 0.4 },
    SHAMAN_CASTER = { SP = 1, SCHOOL_NATURE = 0.9, SCHOOL_FIRE = 0.4,
        SCHOOL_FROST = 0.3, INT = 0.45, SPI = 0.1, STA = 0.35, SPELLHIT = 10,
        SPELLCRIT = 10, MP5 = 1, ARMOR = 0.01 },
    SHAMAN_HEAL = { HEAL = 1, SP = 1, INT = 0.7, SPI = 0.2, STA = 0.3, MP5 = 1.8,
        SPELLCRIT = 8, ARMOR = 0.01 },
    MAGE = { SP = 1, SCHOOL_FIRE = 0.8, SCHOOL_FROST = 0.8, SCHOOL_ARCANE = 0.5,
        INT = 0.45, SPI = 0.2, STA = 0.35, SPELLHIT = 12, SPELLCRIT = 10, MP5 = 0.8,
        RDPS = 1.5, ARMOR = 0.01 },
    WARLOCK = { SP = 1, SCHOOL_SHADOW = 0.9, SCHOOL_FIRE = 0.5, INT = 0.35,
        SPI = 0.25, STA = 0.5, SPELLHIT = 12, SPELLCRIT = 6, MP5 = 0.6, RDPS = 1.5,
        ARMOR = 0.01 },
    DRUID_FERAL = { AGI = 1, STR = 1, STA = 0.8, AP = 0.5, CRIT = 12, HIT = 10,
        ARMOR = 0.04, DEF = 0.5, DODGE = 8, INT = 0.15, SPI = 0.05 },
    DRUID_CASTER = { SP = 1, SCHOOL_NATURE = 0.8, SCHOOL_ARCANE = 0.6, INT = 0.45,
        SPI = 0.25, STA = 0.35, SPELLHIT = 10, SPELLCRIT = 10, MP5 = 0.8,
        ARMOR = 0.01 },
    DRUID_HEAL = { HEAL = 1, SP = 1, INT = 0.6, SPI = 0.5, STA = 0.3, MP5 = 1.6,
        SPELLCRIT = 8, ARMOR = 0.01 },
}

-- Class token -> the spec used with no talent points, and the background name
-- fragments that pick another one. A tree that matches no fragment (Arms,
-- Fury, Retribution's "PaladinCombat", Balance ...) keeps the default.
local SPECS = {
    WARRIOR = { default = "WARRIOR_DPS", trees = { { "Protection", "WARRIOR_TANK" } } },
    PALADIN = { default = "PALADIN_DPS", trees = { { "Holy", "PALADIN_HEAL" },
        { "Protection", "PALADIN_TANK" } } },
    HUNTER = { default = "HUNTER", trees = {} },
    ROGUE = { default = "ROGUE", trees = {} },
    PRIEST = { default = "PRIEST_HEAL", trees = { { "Shadow", "PRIEST_DPS" } } },
    SHAMAN = { default = "SHAMAN_MELEE", trees = { { "Elemental", "SHAMAN_CASTER" },
        { "Restoration", "SHAMAN_HEAL" } } },
    MAGE = { default = "MAGE", trees = {} },
    WARLOCK = { default = "WARLOCK", trees = {} },
    DRUID = { default = "DRUID_CASTER", trees = { { "Feral", "DRUID_FERAL" },
        { "Restoration", "DRUID_HEAL" } } },
}

-- Tooltip slot label -> slot group. Shirts, tabards and bags are not gear here.
local SLOT_LABELS = {
    { "INVTYPE_HEAD", "Head", "HEAD" },
    { "INVTYPE_NECK", "Neck", "NECK" },
    { "INVTYPE_SHOULDER", "Shoulder", "SHOULDER" },
    { "INVTYPE_CLOAK", "Back", "BACK" },
    { "INVTYPE_CHEST", "Chest", "CHEST" },
    { "INVTYPE_ROBE", "Chest", "CHEST" },
    { "INVTYPE_WRIST", "Wrist", "WRIST" },
    { "INVTYPE_HAND", "Hands", "HANDS" },
    { "INVTYPE_WAIST", "Waist", "WAIST" },
    { "INVTYPE_LEGS", "Legs", "LEGS" },
    { "INVTYPE_FEET", "Feet", "FEET" },
    { "INVTYPE_FINGER", "Finger", "FINGER" },
    { "INVTYPE_TRINKET", "Trinket", "TRINKET" },
    { "INVTYPE_WEAPON", "One-Hand", "ONEHAND" },
    { "INVTYPE_WEAPONMAINHAND", "Main Hand", "ONEHAND" },
    { "INVTYPE_2HWEAPON", "Two-Hand", "TWOHAND" },
    { "INVTYPE_WEAPONOFFHAND", "Off Hand", "OFFHAND" },
    { "INVTYPE_SHIELD", "Off Hand", "OFFHAND" },
    { "INVTYPE_HOLDABLE", "Held In Off-hand", "OFFHAND" },
    { "INVTYPE_RANGED", "Ranged", "RANGED" },
    { "INVTYPE_RANGEDRIGHT", "Ranged", "RANGED" },
    { "INVTYPE_THROWN", "Thrown", "RANGED" },
    { "INVTYPE_RELIC", "Relic", "RANGED" },
}

local GROUP_SLOTS = {
    HEAD = { "HeadSlot" }, NECK = { "NeckSlot" }, SHOULDER = { "ShoulderSlot" },
    BACK = { "BackSlot" }, CHEST = { "ChestSlot" }, WRIST = { "WristSlot" },
    HANDS = { "HandsSlot" }, WAIST = { "WaistSlot" }, LEGS = { "LegsSlot" },
    FEET = { "FeetSlot" }, FINGER = { "Finger0Slot", "Finger1Slot" },
    TRINKET = { "Trinket0Slot", "Trinket1Slot" }, ONEHAND = { "MainHandSlot" },
    TWOHAND = { "MainHandSlot" }, OFFHAND = { "SecondaryHandSlot" },
    RANGED = { "RangedSlot" },
}

local GEAR_SLOTS = {
    "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "WristSlot",
    "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot",
    "Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

-- Base-stat lines: client format global, English fallback, stat key.
local STAT_FORMATS = {
    { "ITEM_MOD_STRENGTH", "%c%d Strength", "STR" },
    { "ITEM_MOD_AGILITY", "%c%d Agility", "AGI" },
    { "ITEM_MOD_STAMINA", "%c%d Stamina", "STA" },
    { "ITEM_MOD_INTELLECT", "%c%d Intellect", "INT" },
    { "ITEM_MOD_SPIRIT", "%c%d Spirit", "SPI" },
    { "ARMOR_TEMPLATE", "%d Armor", "ARMOR" },
    { "SHIELD_BLOCK_TEMPLATE", "%d Block", "BLOCKVALUE" },
    { "DPS_TEMPLATE", "(%.1f damage per second)", "WDPS" },
}

-- "Equip:" effects, after the prefix is removed. English only.
local EQUIP_PATTERNS = {
    { "^Increases damage and healing done by magical spells and effects by up to (%d+)", "SP" },
    { "^Increases healing done by spells and effects by up to (%d+)", "HEAL" },
    { "^Improves your chance to hit with spells by (%d+)%%", "SPELLHIT" },
    { "^Improves your chance to get a critical strike with spells by (%d+)%%", "SPELLCRIT" },
    { "^Improves your chance to hit by (%d+)%%", "HIT" },
    { "^Improves your chance to get a critical strike by (%d+)%%", "CRIT" },
    { "^%+(%d+) ranged Attack Power%.?$", "RAP" },
    { "^%+(%d+) Attack Power%.?$", "AP" },
    { "^Restores (%d+) mana per 5 sec", "MP5" },
    { "^Restores (%d+) health per 5 sec", "HP5" },
    { "^Increased Defense %+(%d+)", "DEF" },
    { "^Increases your chance to dodge an attack by (%d+)%%", "DODGE" },
    { "^Increases your chance to parry an attack by (%d+)%%", "PARRY" },
    { "^Increases your chance to block attacks with a shield by (%d+)%%", "BLOCK" },
    { "^Increases the block value of your shield by (%d+)", "BLOCKVALUE" },
}
local SCHOOL_PATTERN = "^Increases damage done by (%a+) spells and effects by up to (%d+)"

local parser = nil

-- A client format string ("%c%d Stamina") as an anchored Lua pattern.
local function FormatPattern(format)
    local out = "^"
    local position = 1
    local length = string.len(format)
    while position <= length do
        local char = string.sub(format, position, position)
        if char == "%" then
            local _, finish, spec = string.find(format, "^%%[%d%.%$]*([cdsf%%])", position)
            if not finish then
                return nil
            end
            if spec == "d" then
                out = out .. "(%d+)"
            elseif spec == "c" then
                out = out .. "([%+%-])"
            elseif spec == "f" then
                out = out .. "([%d%.]+)"
            elseif spec == "s" then
                out = out .. "(.-)"
            else
                out = out .. "%%"
            end
            position = finish + 1
        else
            if string.find(char, "[%(%)%.%[%]%*%+%-%?%^%$]") then
                out = out .. "%"
            end
            out = out .. char
            position = position + 1
        end
    end
    return out .. "$"
end

local function Parser()
    if parser then
        return parser
    end
    parser = { labels = {}, stats = {} }
    local index = 1
    while index <= table.getn(SLOT_LABELS) do
        local entry = SLOT_LABELS[index]
        parser.labels[Client.GetGlobalString(entry[1]) or entry[2]] = entry[3]
        parser.labels[entry[2]] = entry[3]
        index = index + 1
    end
    index = 1
    while index <= table.getn(STAT_FORMATS) do
        local entry = STAT_FORMATS[index]
        local format = Client.GetGlobalString(entry[1]) or entry[2]
        local pattern = FormatPattern(format)
        if pattern then
            table.insert(parser.stats, { pattern = pattern, key = entry[3],
                signed = string.find(format, "%%c") ~= nil })
        end
        index = index + 1
    end
    parser.equip = Client.GetGlobalString("ITEM_SPELL_TRIGGER_ONEQUIP") or "Equip:"
    return parser
end

local function Clean(text)
    if type(text) ~= "string" then
        return nil
    end
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then
        return nil
    end
    return text
end

local function Add(stats, key, value)
    stats[key] = (stats[key] or 0) + value
end

local function ParseStatLine(text, stats)
    local rules = Parser()
    local index = 1
    while index <= table.getn(rules.stats) do
        local rule = rules.stats[index]
        local _, _, first, second = string.find(text, rule.pattern)
        if first then
            if rule.signed then
                local value = tonumber(second) or 0
                if first == "-" then
                    value = -value
                end
                Add(stats, rule.key, value)
            else
                Add(stats, rule.key, tonumber(first) or 0)
            end
            return
        end
        index = index + 1
    end

    local prefix = rules.equip
    if string.sub(text, 1, string.len(prefix)) ~= prefix then
        return
    end
    text = string.gsub(string.sub(text, string.len(prefix) + 1), "^%s+", "")
    local _, _, school, amount = string.find(text, SCHOOL_PATTERN)
    if school then
        Add(stats, "SCHOOL_" .. string.upper(school), tonumber(amount) or 0)
        return
    end
    index = 1
    while index <= table.getn(EQUIP_PATTERNS) do
        local _, _, value = string.find(text, EQUIP_PATTERNS[index][1])
        if value then
            Add(stats, EQUIP_PATTERNS[index][2], tonumber(value) or 0)
            return
        end
        index = index + 1
    end
end

-- Tooltip rows -> { group, stats }. Row 1 is the item name. The slot row is
-- the first whose left text is a slot label; its right text is the subtype.
function GearAdvisor.ParseItem(lines)
    local item = { stats = {} }
    if type(lines) ~= "table" then
        return item
    end
    local labels = Parser().labels
    local index = 2
    while index <= table.getn(lines) do
        local line = lines[index]
        local left = Clean(line.text or line.left)
        if left then
            if not item.group and labels[left] then
                item.group = labels[left]
            else
                ParseStatLine(left, item.stats)
            end
        end
        index = index + 1
    end
    if item.stats.WDPS then
        if item.group == "RANGED" then
            item.stats.RDPS = item.stats.WDPS
        else
            item.stats.MDPS = item.stats.WDPS
        end
        item.stats.WDPS = nil
    end
    return item
end

function GearAdvisor.Score(stats, weights)
    local score = 0
    for key, value in pairs(stats) do
        local weight = weights[key]
        if weight then
            score = score + weight * value
        end
    end
    return score
end

-- The spec key for the current class and talents.
function GearAdvisor:ResolveSpec()
    local _, token = Client.GetPlayerClass()
    local class = token and SPECS[token]
    if not class then
        return nil
    end
    local trees = Client.GetTalentTrees()
    local best = nil
    local index = 1
    while index <= table.getn(trees) do
        if trees[index].points > 0 and (not best or trees[index].points > best.points) then
            best = trees[index]
        end
        index = index + 1
    end
    if best then
        index = 1
        while index <= table.getn(class.trees) do
            if string.find(best.background, class.trees[index][1], 1, true) then
                return class.trees[index][2]
            end
            index = index + 1
        end
    end
    return class.default
end

-- One equipped slot, parsed and scored once per evaluation. false when the
-- slot cannot be read; an empty slot is an item with no stats.
local function Equipped(cache, slotName, weights)
    if cache[slotName] ~= nil then
        return cache[slotName]
    end
    local lines = Client.GetEquippedItemTooltipLines(slotName)
    local entry = false
    if lines then
        local item = GearAdvisor.ParseItem(lines)
        entry = { group = item.group, score = GearAdvisor.Score(item.stats, weights),
            weapon = (item.stats.MDPS or 0) > 0 }
    end
    cache[slotName] = entry
    return entry
end

-- The score a reward of `group` has to beat, or nil when it cannot be known.
-- Rings and trinkets replace the weaker of the two; a two-hander replaces
-- both hands; a one-hander replaces the weaker weapon when two are wielded;
-- an off-hand next to a two-hander has to beat the two-hander.
local function EquippedScore(group, cache, weights)
    local slots = GROUP_SLOTS[group]
    if not slots then
        return nil
    end
    if group == "TWOHAND" or group == "OFFHAND" or group == "ONEHAND" then
        local main = Equipped(cache, "MainHandSlot", weights)
        local off = Equipped(cache, "SecondaryHandSlot", weights)
        if not main or not off then
            return nil
        end
        if group == "TWOHAND" then
            return main.score + off.score
        elseif group == "OFFHAND" then
            if main.group == "TWOHAND" then
                return main.score
            end
            return off.score
        end
        if off.weapon and off.score < main.score then
            return off.score
        end
        return main.score
    end
    local lowest = nil
    local index = 1
    while index <= table.getn(slots) do
        local entry = Equipped(cache, slots[index], weights)
        if not entry then
            return nil
        end
        if not lowest or entry.score < lowest then
            lowest = entry.score
        end
        index = index + 1
    end
    return lowest
end

-- Ranks the offered choices. Returns { [choiceIndex] = { arrow, coin } } and
-- whether every input was available (an incomplete result is not cached).
function GearAdvisor:Evaluate(rewards, spec)
    local weights = spec and WEIGHTS[spec]
    local marks = {}
    local complete = true
    local cache = {}
    local upgrades = {}
    local total = table.getn(rewards)
    local index = 1
    while index <= total do
        local reward = rewards[index]
        marks[index] = { arrow = nil, coin = false }
        if weights and reward.usable then
            local lines = Client.GetQuestGiverItemTooltipLines("choice", index)
            if not lines then
                complete = false
            else
                local item = GearAdvisor.ParseItem(lines)
                reward.group = item.group
                if item.group then
                    reward.score = GearAdvisor.Score(item.stats, weights)
                    reward.equipped = EquippedScore(item.group, cache, weights)
                    if reward.equipped == nil then
                        complete = false
                    elseif reward.score > reward.equipped then
                        table.insert(upgrades, index)
                    else
                        marks[index].arrow = "worse"
                    end
                end
            end
        end
        index = index + 1
    end

    table.sort(upgrades, function(a, b)
        local gainA = rewards[a].score - rewards[a].equipped
        local gainB = rewards[b].score - rewards[b].equipped
        if gainA ~= gainB then
            return gainA > gainB
        end
        return a < b
    end)
    if upgrades[1] then
        marks[upgrades[1]].arrow = "best"
    end
    if upgrades[2] then
        marks[upgrades[2]].arrow = "second"
    end

    -- The coin only means something as a comparison: every choice must have
    -- a price, or none is marked.
    local database = UQ:GetModule("Database")
    local highest = nil
    index = 1
    while index <= total do
        local price = database and database:GetItemSellPriceByName(rewards[index].name)
        rewards[index].price = price
        if price == nil then
            highest = nil
            if not (database and database.itemNameIndexReady) then
                complete = false
            end
            break
        end
        if not highest or price > highest then
            highest = price
        end
        index = index + 1
    end
    if total >= 2 and highest and highest > 0 then
        index = 1
        while index <= total do
            if rewards[index].price == highest then
                marks[index].coin = true
            end
            index = index + 1
        end
    end
    return marks, complete
end

local function Enabled()
    local config = UQ:GetModule("Config")
    return not (config and config:Get("questRewardGearAdvisor") == false)
end

function GearAdvisor:Clear()
    if self.applied then
        Client.ClearQuestRewardGearMarks()
        self.applied = nil
    end
    self.signature = nil
    self.incomplete = nil
    self.marks = nil
end

-- The offered choices, or nil while any of them is not cached yet.
local function ReadChoices()
    local choices = Client.GetQuestGiverRewardCounts()
    local rewards = {}
    local index = 1
    while index <= choices do
        local name, _, usable = Client.GetQuestGiverItemDetails("choice", index)
        if not name then
            return nil
        end
        rewards[index] = { name = name, usable = usable }
        index = index + 1
    end
    return rewards
end

local function Signature(rewards, spec)
    local parts = { spec or "-", tostring(Client.GetPlayerLevel() or 0) }
    local index = 1
    while index <= table.getn(rewards) do
        table.insert(parts, rewards[index].name .. (rewards[index].usable and "+" or "-"))
        index = index + 1
    end
    index = 1
    while index <= table.getn(GEAR_SLOTS) do
        table.insert(parts, tostring(Client.GetEquippedItemLink(GEAR_SLOTS[index])))
        index = index + 1
    end
    return table.concat(parts, "|")
end

function GearAdvisor:Refresh()
    if not Enabled() or not Client.IsQuestGiverCompletionShown() then
        self:Clear()
        return
    end
    local rewards = ReadChoices()
    if not rewards or table.getn(rewards) == 0 then
        self:Clear()
        return
    end
    local spec = self:ResolveSpec()
    local signature = Signature(rewards, spec)
    if signature ~= self.signature
        or (self.incomplete and self.incomplete >= RETRY_PASSES) then
        local marks, complete = self:Evaluate(rewards, spec)
        self.marks = marks
        self.rewards = rewards
        self.signature = signature
        self.incomplete = (not complete) and 0 or nil
    elseif self.incomplete then
        self.incomplete = self.incomplete + 1
    end

    -- Choice buttons come first on the panel; each is also checked by name,
    -- so a button this module did not predict is never marked.
    local index = 1
    while index <= 10 do
        local mark = self.marks[index]
        local reward = rewards[index]
        if mark and reward and Client.GetQuestRewardButtonText(index) == reward.name then
            Client.SetQuestRewardGearMark(index, mark.arrow, mark.coin)
        else
            Client.SetQuestRewardGearMark(index, nil, false)
        end
        index = index + 1
    end
    self.applied = true
end

-- Diagnostic lines for /uq gear: the spec and each choice's numbers.
function GearAdvisor:Describe()
    local lines = { "spec " .. tostring(self:ResolveSpec()) }
    local rewards = self.rewards
    if not rewards or not self.marks then
        return lines
    end
    local index = 1
    while index <= table.getn(rewards) do
        local reward = rewards[index]
        local mark = self.marks[index] or {}
        table.insert(lines, string.format("%d %s: usable=%s slot=%s score=%s equipped=%s price=%s arrow=%s coin=%s",
            index, reward.name, tostring(reward.usable), tostring(reward.group),
            reward.score and string.format("%.1f", reward.score) or "-",
            reward.equipped and string.format("%.1f", reward.equipped) or "-",
            tostring(reward.price), tostring(mark.arrow), tostring(mark.coin)))
        index = index + 1
    end
    return lines
end

function GearAdvisor:OnInit()
    UQ:DeclareCapability("questRewardGearAdvisor", "documented",
        "GetQuestItemInfo (isUsable) and GameTooltip:SetQuestItem are documented "
        .. "and not probed. The private tooltip scanner (SetInventoryItem, NumLines, "
        .. "TextLeftN) is FOCUSED_RUNTIME_PROBE (bags.equipped_bag_type_via_tooltip) "
        .. "and GetTalentTabInfo's background return is FOCUSED_RUNTIME_PROBE "
        .. "(talent.tab_info_background_textures). Equip: effects are parsed in "
        .. "English only; sell prices are bundled Vanilla data. The upside-down "
        .. "arrow uses swapped top/bottom texture coordinates, not probed here")
end

function GearAdvisor:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("quest.gearadvisor", POLL_INTERVAL, function()
        GearAdvisor:Refresh()
    end)
end
