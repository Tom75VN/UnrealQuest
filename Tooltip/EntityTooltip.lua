--[[
UnrealQuest / Tooltip/EntityTooltip.lua

Adds live quest-objective progress to the client's entity tooltip. The native
tooltip is visually replaced by ONE combined addon-owned tooltip that reprints
the native rows (read back through Client.GetGameTooltipLines) above the quest
rows, so the player only ever sees a single tooltip. Standalone and UnrealUI
Classic use native chrome, while UnrealUI Modern uses the flat modern style.
Only if the native rows cannot be read, or alpha suppression fails, does the
addon fall back to leaving the native tooltip alone and attaching a separate
progress panel beneath it.

The mechanism is pfQuest's, because pfQuest's is confirmed working on this
install (Interface/AddOns/pfQuest/map.lua:201-320, pfMap.tooltip's OnShow and
pfMap:ShowTooltip -- see docs/CLIENT-COMPATIBILITY.md item 9). Three parts:

  1. Identity comes from the tooltip's own rendered first line
     (GameTooltipTextLeft1), never from UnitName("mouseover") -- see
     Client.GetGameTooltipUnitLabel for why.
  2. Detection runs synchronously from GameTooltip's own OnShow, via a child
     frame parented to it (Client.HookGameTooltipShow), with the driver poll as
     the correctness path.
  3. What the creature is actually for is answered by Data/ObjectiveMatch.lua,
     which parses the live quest log line the way pfQuest does. This file owns
     no matching of its own; it turns an answer into tooltip lines.

The quest rows are not added to GameTooltip. This client does not reliably
relayout Lua-added lines, and a world-object tooltip may rebuild its native
content repeatedly while it remains shown. The addon-owned replacement avoids
both failure modes and lets progress change without mutating native content.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local EntityTooltip = UQ:NewModule("EntityTooltip")

local POLL_INTERVAL = 0.1

-- The addon's accent orange, matching the quest title colouring used elsewhere.
local TITLE_R, TITLE_G, TITLE_B = 0.96, 0.68, 0.04

-- State ---------------------------------------------------------------------

EntityTooltip.lastUnitKey = nil
EntityTooltip.lastQuestStamp = nil
EntityTooltip.lastStyle = nil
EntityTooltip.lastNativeStamp = nil
EntityTooltip.panel = nil
EntityTooltip.panels = {}
EntityTooltip.replacingNative = false

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
--   matches > 0, presentationFailures == matches -> the owned panel could not
--                               be created or shown
--   matches > 0, presentationFailures < matches  -> the panel itself works;
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
EntityTooltip.presentationFailureCount = 0
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
                    questTitleKey = quest.titleKey,
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

function EntityTooltip:RecordPresentationFailure()
    self.presentationFailureCount = self.presentationFailureCount + 1
    local config = UQ:GetModule("Config")
    if config then
        config:SetSectionEntry("tooltipDiagnostics", "presentationFailures",
            self.presentationFailureCount)
    end
end

function EntityTooltip:GetStatus()
    local matcher = UQ:GetModule("ObjectiveMatch")
    local patterns = matcher and matcher:GetStatus() or {}
    return {
        matches = self.matchCount,
        directMatches = self.directMatchCount,
        databaseMatches = self.databaseMatchCount,
        presentationFailures = self.presentationFailureCount,
        currentUnit = self.lastUnitKey,
        style = self.lastStyle,
        replacingNative = self.replacingNative,
        refreshCount = self.refreshCount,
        labelReads = self.labelReads,
        lastSeenLabel = self.lastSeenLabel,
        patternsResolved = patterns.patternsResolved or 0,
        patternsExpected = patterns.patternsExpected or 0,
    }
end

-- Refresh -------------------------------------------------------------------

local function HidePanels(module)
    local _, panel
    for _, panel in pairs(module.panels) do
        Client.HideEntityTooltipPanel(panel)
    end
    module.panel = nil
    module.replacingNative = false
    Client.SetNativeEntityTooltipSuppressed(false)
end

-- Identifies the native content so the owned replacement is rebuilt when the
-- native tooltip's own rows change (a creature tooltip repopulates while the
-- hover lasts) and left alone when they repeat unchanged.
local function NativeStamp(nativeLines)
    local stamp = ""
    local index = 1
    local total = table.getn(nativeLines or {})
    while index <= total do
        local line = nativeLines[index]
        stamp = stamp .. "" .. (line.text or line.left or "")
            .. "" .. (line.right or "")
        index = index + 1
    end
    return stamp
end

local function CombinedLines(nativeLines, unitKey, questLines)
    local lines = {}
    local index = 1
    local total = table.getn(nativeLines)
    while index <= total do
        table.insert(lines, nativeLines[index])
        index = index + 1
    end

    index = 1
    total = table.getn(questLines)
    -- World objects commonly share their name with the quest. One combined
    -- tooltip should not print that title twice; the objective row is enough.
    if total > 0 and (questLines[1].questTitleKey == unitKey
            or UQ.NameKey(questLines[1].text) == unitKey) then
        index = 2
    end
    while index <= total do
        table.insert(lines, questLines[index])
        index = index + 1
    end
    return lines
end

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
        self.lastQuestStamp = nil
        self.lastStyle = nil
        self.lastNativeStamp = nil
        HidePanels(self)
        return
    end

    local matcher = UQ:GetModule("ObjectiveMatch")
    local matcherStatus = matcher and matcher:GetStatus() or {}
    local questStamp = matcherStatus.questStamp or 0
    local style = Client.GetEntityTooltipStyle()
    -- Every row the native tooltip currently shows, so the replacement can
    -- carry them itself. nil means the rows could not be read, which is the
    -- only case where the native tooltip is left visible.
    local nativeLines = Client.GetGameTooltipLines()
    local nativeStamp = NativeStamp(nativeLines)
    -- The native tooltip can repopulate many times during one world-object
    -- hover. Reassert alpha suppression on every poll, but rebuild the owned
    -- content only when its entity, quest model, theme, or presentation route
    -- changes.
    if self.lastUnitKey == unitKey and self.lastQuestStamp == questStamp
            and self.lastStyle == style and self.lastNativeStamp == nativeStamp then
        if self.replacingNative then
            if Client.SetNativeEntityTooltipSuppressed(true) then
                Client.CoverNativeEntityTooltip(self.panel)
                return
            end
        else
            Client.SetNativeEntityTooltipSuppressed(false)
            return
        end
    end
    self.lastUnitKey = unitKey
    self.lastQuestStamp = questStamp
    self.lastStyle = style
    self.lastNativeStamp = nativeStamp

    local lines, direct, viaDatabase = self:BuildLines(unitKey)
    if not lines then
        HidePanels(self)
        return
    end

    self:RecordMatch(direct, viaDatabase)

    local panel = self.panels[style]
    if not panel then
        local name = style == "modern" and "UnrealQuestEntityTooltipModern"
            or "UnrealQuestEntityTooltipNative"
        panel = Client.CreateEntityTooltipPanel(name, style)
        self.panels[style] = panel
    end
    self.panel = panel

    local otherStyle = style == "modern" and "native" or "modern"
    Client.HideEntityTooltipPanel(self.panels[otherStyle])

    local shown = false
    self.replacingNative = false
    if panel and nativeLines then
        shown = Client.ShowEntityTooltipPanel(panel,
            CombinedLines(nativeLines, unitKey, lines), true)
        if shown and Client.SetNativeEntityTooltipSuppressed(true) then
            self.replacingNative = true
        else
            -- Alpha suppression is isolated behind readback because it is not
            -- measured specifically on GameTooltip. Preserve native content
            -- and fall back to the stable attached panel if it is unavailable.
            Client.SetNativeEntityTooltipSuppressed(false)
            shown = Client.ShowEntityTooltipPanel(panel, lines, false)
        end
    elseif panel then
        Client.SetNativeEntityTooltipSuppressed(false)
        shown = Client.ShowEntityTooltipPanel(panel, lines, false)
    end

    if not panel or not shown then
        -- Creation can fail transiently during UI startup. Do not cache that
        -- failure as a completed presentation for this hover.
        self.lastUnitKey = nil
        self.lastQuestStamp = nil
        self.lastStyle = nil
        self.lastNativeStamp = nil
        HidePanels(self)
        self:RecordPresentationFailure()
    end
end

-- Lifecycle -----------------------------------------------------------------

function EntityTooltip:OnEnable()
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("tooltip.entity", POLL_INTERVAL, function()
            EntityTooltip:Refresh()
        end)
        -- Refresh runs synchronously here too, not just via driver:Wake, so the
        -- combined or attached progress tooltip is ready with the native one. The poll
        -- above remains the correctness guarantee if this never fires.
        Client.HookGameTooltipShow(function()
            EntityTooltip:Refresh()
        end)
    end
end
