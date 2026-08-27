--[[
UnrealQuest / Tooltip/EntityTooltip.lua

Adds live quest-objective progress to the client's normal unit tooltip: hover a
creature a quest wants killed and the tooltip gains the quest's title plus
"- Creature: killed/needed".

The mechanism is pfQuest's, because pfQuest's is confirmed working on this
install (Interface/AddOns/pfQuest/map.lua:201-320, pfMap.tooltip's OnShow and
pfMap:ShowTooltip -- see docs/CLIENT-COMPATIBILITY.md item 9). Three parts:

  1. Identity comes from the tooltip's own rendered first line
     (GameTooltipTextLeft1), never from UnitName("mouseover") -- see
     Client.GetGameTooltipUnitLabel for why.
  2. The append runs synchronously from GameTooltip's own OnShow, via a child
     frame parented to it (Client.HookGameTooltipShow), and only ever calls
     AddLine. Nothing here clears or rebuilds the tooltip.
  3. What the creature is actually for is answered by Data/ObjectiveMatch.lua,
     which parses the live quest log line the way pfQuest does. This file owns
     no matching of its own; it turns an answer into tooltip lines.

Known limitation, unchanged and accepted: AddLine cannot overwrite a line that
is already drawn and this module deliberately never calls SetUnit (see
Compatibility/ClientAPI.lua), so a counter that advances while the player keeps
hovering the same creature stays at the value written on the first hover until
they move off and back.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local EntityTooltip = UQ:NewModule("EntityTooltip")

local POLL_INTERVAL = 0.1

-- The addon's accent orange, matching the quest title colouring used elsewhere.
local TITLE_R, TITLE_G, TITLE_B = 0.96, 0.68, 0.04

-- State ---------------------------------------------------------------------

EntityTooltip.lastUnitKey = nil
EntityTooltip.lastTooltipLines = nil

-- Diagnostics, persisted the same way WorldMapPins settled its own "did the
-- mouse/click ever reach the addon" questions from SavedVariables instead of
-- a screenshot (see Map/WorldMapPins.lua RecordHover/RecordGiverHover). A
-- session where /uq tooltip or SavedVariables shows nothing at all under
-- "tooltipDiagnostics" means Refresh never got past the first line read.
--   refreshCount == 0        -> the driver job or the OnShow hook never calls
--                               Refresh (module enable/registration problem)
--   refreshCount > 0, labelReads == 0 -> the tooltip was never open during a
--                               refresh, or GameTooltipTextLeft1 never
--                               resolved to text (identity problem). This is
--                               the question lastSeenLabel alone could not
--                               answer, because it is overwritten with
--                               "<none>" as soon as the mouse leaves.
--   labelReads > 0, matches == 0 -> creature names were read but none ever
--                               matched an objective (data/matching problem)
--   matches > 0, appendFailures == matches -> AddLine never succeeds
--                               (GameTooltip resolution or IsShown gating)
--   matches > 0, appendFailures < matches  -> the append call itself works;
--                               if lines still are not seen in game the
--                               remaining question is purely visual timing
-- directMatches vs databaseMatches splits the two paths in ObjectiveMatch: a
-- direct match is a kill objective recognized from its own log line and needs
-- nothing else to work, a database match is an item objective resolved through
-- a quest ID.
EntityTooltip.refreshCount = 0
EntityTooltip.labelReads = 0
EntityTooltip.matchCount = 0
EntityTooltip.directMatchCount = 0
EntityTooltip.databaseMatchCount = 0
EntityTooltip.appendFailureCount = 0
EntityTooltip.lastSeenKey = false
EntityTooltip.lastSeenLabel = nil

-- Lines ---------------------------------------------------------------------

-- pfQuest's own line shape: a grey dash, the objective's name, then the
-- counters coloured by progress.
local function ProgressLine(matcher, result)
    if result.name and type(result.have) == "number" and type(result.need) == "number" then
        local r, g, b = matcher:ProgressColor(result.have, result.need)
        return {
            text = "|cffaaaaaa- |r" .. result.name .. ": " .. result.have .. "/" .. result.need,
            r = r, g = g, b = b,
        }
    end
    if type(result.text) == "string" and result.text ~= "" then
        return { text = "|cffaaaaaa- |r" .. result.text, r = 1, g = 1, b = 1 }
    end
    return nil
end

-- Returns the tooltip lines for a hovered creature, plus how many of them came
-- from each of ObjectiveMatch's two paths, or nil when the creature satisfies
-- nothing in the log.
function EntityTooltip:BuildLines(unitKey)
    local matcher = UQ:GetModule("ObjectiveMatch")
    if not matcher then
        return nil
    end
    local results, direct, viaDatabase = matcher:FindForUnit(unitKey)
    if not results then
        return nil
    end

    local lines = {}
    local seen = {}
    local titled = {}

    local index = 1
    local total = table.getn(results)
    while index <= total do
        local result = results[index]
        local quest = result.quest
        local lineKey = (quest.titleKey or "") .. "\031" .. (result.text or "")
        if not seen[lineKey] then
            seen[lineKey] = true
            if not titled[quest.titleKey or ""] then
                titled[quest.titleKey or ""] = true
                table.insert(lines, {
                    text = UQ.GetQuestDisplayTitle(quest),
                    r = TITLE_R, g = TITLE_G, b = TITLE_B,
                })
            end
            local line = ProgressLine(matcher, result)
            if line then
                table.insert(lines, line)
            end
        end
        index = index + 1
    end

    if table.getn(lines) == 0 then
        return nil
    end
    return lines, direct, viaDatabase
end

-- Diagnostics ---------------------------------------------------------------

function EntityTooltip:RecordSeen()
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    config:SetSectionEntry("tooltipDiagnostics", "refreshCount", self.refreshCount)
    config:SetSectionEntry("tooltipDiagnostics", "labelReads", self.labelReads)
    config:SetSectionEntry("tooltipDiagnostics", "lastSeenLabel", self.lastSeenLabel or "<none>")
end

function EntityTooltip:RecordMatch(direct, viaDatabase)
    self.matchCount = self.matchCount + 1
    self.directMatchCount = self.directMatchCount + (direct or 0)
    self.databaseMatchCount = self.databaseMatchCount + (viaDatabase or 0)
    local config = UQ:GetModule("Config")
    if config then
        config:SetSectionEntry("tooltipDiagnostics", "matches", self.matchCount)
        config:SetSectionEntry("tooltipDiagnostics", "directMatches", self.directMatchCount)
        config:SetSectionEntry("tooltipDiagnostics", "databaseMatches", self.databaseMatchCount)
    end
end

function EntityTooltip:RecordAppendFailure()
    self.appendFailureCount = self.appendFailureCount + 1
    local config = UQ:GetModule("Config")
    if config then
        config:SetSectionEntry("tooltipDiagnostics", "appendFailures", self.appendFailureCount)
    end
end

function EntityTooltip:GetStatus()
    local matcher = UQ:GetModule("ObjectiveMatch")
    local patterns = matcher and matcher:GetStatus() or {}
    return {
        matches = self.matchCount,
        directMatches = self.directMatchCount,
        databaseMatches = self.databaseMatchCount,
        appendFailures = self.appendFailureCount,
        currentUnit = self.lastUnitKey,
        refreshCount = self.refreshCount,
        labelReads = self.labelReads,
        lastSeenLabel = self.lastSeenLabel,
        patternsResolved = patterns.patternsResolved or 0,
        patternsExpected = patterns.patternsExpected or 0,
    }
end

-- Refresh -------------------------------------------------------------------

function EntityTooltip:Refresh()
    self.refreshCount = self.refreshCount + 1

    -- Identity comes from the tooltip's own rendered first line, not
    -- UnitName("mouseover") -- see Client.GetGameTooltipUnitLabel for why.
    local unitLabel = Client.GetGameTooltipUnitLabel()
    local unitKey = UQ.NameKey(unitLabel)

    if unitKey then
        self.labelReads = self.labelReads + 1
    end

    -- Recorded on every hover CHANGE (including to and from nothing), not on
    -- every poll tick, so this stays cheap while still proving the job runs at
    -- all and what it actually reads. lastSeenLabel deliberately keeps the last
    -- real name rather than being reset to nothing when the mouse leaves.
    if unitKey ~= self.lastSeenKey then
        self.lastSeenKey = unitKey
        if unitLabel then
            self.lastSeenLabel = unitLabel
        end
        self:RecordSeen()
    end

    if not unitKey then
        self.lastUnitKey = nil
        self.lastTooltipLines = nil
        return
    end

    local lineCount = Client.GetGameTooltipLineCount()
    -- A drop below what we last left behind means something else (the client
    -- itself, most likely) rebuilt the tooltip since our last successful
    -- append and wiped our lines; treat that the same as fresh content. This
    -- is a pure append, never a rebuild: nothing here ever clears or resets
    -- the tooltip itself (see Compatibility/ClientAPI.lua for why calling
    -- GameTooltip:SetUnit ourselves was tried and reverted), so whatever the
    -- client or another addon already put in GameTooltip is never touched.
    if self.lastUnitKey == unitKey and self.lastTooltipLines
        and (not lineCount or lineCount >= self.lastTooltipLines) then
        return
    end

    local lines, direct, viaDatabase = self:BuildLines(unitKey)
    if not lines then
        self.lastUnitKey = nil
        self.lastTooltipLines = nil
        return
    end

    self:RecordMatch(direct, viaDatabase)

    if Client.AppendGameTooltipLines(lines) then
        self.lastUnitKey = unitKey
        -- NumLines is documented but the module must still avoid appending on
        -- every poll if a future client omits it.
        self.lastTooltipLines = Client.GetGameTooltipLineCount() or 0
    else
        self.lastUnitKey = nil
        self.lastTooltipLines = nil
        self:RecordAppendFailure()
    end
end

-- Lifecycle -----------------------------------------------------------------

function EntityTooltip:OnEnable()
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("tooltip.entity", POLL_INTERVAL, function()
            EntityTooltip:Refresh()
        end)
        -- Refresh runs synchronously here too, not just via driver:Wake, to
        -- match pfMap.tooltip's own synchronous OnShow -> AddLine -> Show
        -- sequence in pfQuest (see Client.HookGameTooltipShow). The scheduled
        -- poll above remains the correctness guarantee if this never fires.
        Client.HookGameTooltipShow(function()
            EntityTooltip:Refresh()
        end)
    end
end
