--[[
UnrealQuest / Tooltip/EntityTooltip.lua

Adds live quest-objective progress to the client's entity tooltip. The native
tooltip is visually replaced by ONE combined addon-owned tooltip that reprints
the native rows (read back through Client.GetGameTooltipLines) above the quest
rows, so the player only ever sees a single tooltip. Standalone uses native
chrome; both UnrealUI themes use the host's flat custom tooltip style.
An opaque owned cover obscures the native frame without changing its alpha or
discovering its regions. Brief empty or partial reads retain the last complete
presentation.

One tooltip means one, with no exception. There used to be a fallback that left
the native tooltip alone and hung a separate progress panel beneath it whenever
the native rows could not be read back -- two boxes on screen, which is the one
outcome this module exists to prevent. It is gone: with nothing to reprint the
native rows into, the addon presents nothing at all and the player keeps their
ordinary tooltip until the rows read back, which the retained snapshot makes at
most one poll away. nativeUnreadable in the diagnostics counts the hovers that
had rows to show and no readable native content to show them with.

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

Under a host theme the replacement is an owned plain Frame with owned rows, not
a GameTooltipTemplate frame -- this client cannot report whether such a frame is
drawing its stock chrome, so the stock look is removed by construction rather
    than suppressed and re-checked. It stays opaque for the complete custom
    mouse-out hold instead of exposing the native fade underneath it; see
    Client.CreateEntityTooltipPanel and Client.SyncEntityTooltipFade.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local EntityTooltip = UQ:NewModule("EntityTooltip")

local POLL_INTERVAL = 0.1
local EMPTY_POLL_LIMIT = 3
local NATIVE_STABLE_POLLS = 3

-- The addon's accent orange, matching the quest title colouring used elsewhere.
local TITLE_R, TITLE_G, TITLE_B = 0.96, 0.68, 0.04

-- State ---------------------------------------------------------------------

EntityTooltip.lastUnitKey = nil
EntityTooltip.lastQuestStamp = nil
EntityTooltip.lastRespawnStamp = nil
EntityTooltip.lastStyle = nil
EntityTooltip.lastNativeStamp = nil
EntityTooltip.panel = nil
EntityTooltip.panels = {}
EntityTooltip.replacingNative = false
EntityTooltip.emptyPolls = 0
EntityTooltip.nativeLines = nil
EntityTooltip.pendingNativeStamp = nil
EntityTooltip.pendingNativePolls = 0
EntityTooltip.heldEmptyReads = 0
EntityTooltip.deferredNativeReads = 0
EntityTooltip.nativeUnreadable = 0
EntityTooltip.presentationCount = 0
EntityTooltip.suspendedForNativeFade = false

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

-- How the recorded drop rate is written. The bundled rates run from 0.0065 to
-- well over 50, so a single precision either drowns a common drop in decimals
-- or rounds a rare one away to "0%" -- which reads as "this never drops" when
-- the truth is "this drops, rarely", the one thing the number exists to tell
-- the player. Precision therefore follows magnitude, and anything under a
-- hundredth of a percent is written as a bound rather than as a figure.
local function FormatDropRate(rate)
    if rate >= 10 then
        return string.format("%.0f", rate)
    end
    if rate >= 1 then
        return string.format("%.1f", rate)
    end
    if rate >= 0.01 then
        return string.format("%.2f", rate)
    end
    return "<0.01"
end

-- The bracketed drop chance appended to an item objective, in pfQuest's own
-- shape (Interface/AddOns/pfQuest/map.lua:306): grey brackets around a figure
-- coloured red-to-green across 0-100%, so a rare drop is legible as rare
-- before the digits are read. Not localized: it is punctuation and a numeral,
-- and "%" is the same symbol in all four shipped languages.
local function DropRateSuffix(matcher, rate)
    if type(rate) ~= "number" or rate <= 0 then
        return ""
    end
    local r, g, b = matcher:ProgressColor(rate, 100)
    local color = string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
    return " |cff555555[|cff" .. color .. FormatDropRate(rate) .. "%|cff555555]|r"
end

-- pfQuest's own line shape: a grey dash, the objective's name, then the
-- counters coloured by progress, and -- for an item the world data knows the
-- loot chance of -- that chance in brackets.
local function ProgressLine(matcher, result)
    local dropRate = DropRateSuffix(matcher, result.dropRate)
    if result.name and type(result.have) == "number" and type(result.need) == "number" then
        local r, g, b = matcher:ProgressColor(result.have, result.need)
        return {
            text = "|cffaaaaaa- |r" .. result.name .. ": " .. result.have .. "/" .. result.need
                .. dropRate,
            r = r, g = g, b = b,
        }
    end
    if type(result.text) == "string" and result.text ~= "" then
        return { text = "|cffaaaaaa- |r" .. result.text .. dropRate, r = 1, g = 1, b = 1 }
    end
    return nil
end

local function FormatRespawnDuration(seconds)
    seconds = math.floor(seconds or 0)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds - hours * 3600) / 60)
    local remainder = seconds - hours * 3600 - minutes * 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, remainder)
    end
    return string.format("%02d:%02d", minutes, remainder)
end

local function RespawnLine(minimum, maximum)
    if type(minimum) ~= "number" or minimum <= 0 then
        return nil
    end
    local duration = FormatRespawnDuration(minimum)
    if type(maximum) == "number" and maximum > minimum then
        duration = duration .. " - " .. FormatRespawnDuration(maximum)
    end
    return { text = UQ.L("TOOLTIP_RESPAWN", duration), r = 0.7, g = 0.7, b = 0.7 }
end

-- Returns the addon rows for a hovered entity: any live quest progress plus
-- the optional bundled respawn duration. The two counters describe only the
-- ObjectiveMatch paths and remain nil for a respawn-only tooltip.
function EntityTooltip:BuildLines(unitKey, respawnMinimum, respawnMaximum)
    local matcher = UQ:GetModule("ObjectiveMatch")
    local results, direct, viaDatabase
    if matcher then
        results, direct, viaDatabase = matcher:FindForUnit(unitKey)
    end

    local lines = {}
    local seen = {}
    local titled = {}

    local index = 1
    local total = table.getn(results or {})
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

    local respawn = RespawnLine(respawnMinimum, respawnMaximum)
    if respawn then
        table.insert(lines, respawn)
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
    config:SetSectionEntry("tooltipDiagnostics", "presentationRevision", "cover-v6")
    config:SetSectionEntry("tooltipDiagnostics", "heldEmptyReads", self.heldEmptyReads)
    config:SetSectionEntry("tooltipDiagnostics", "deferredNativeReads", self.deferredNativeReads)
    config:SetSectionEntry("tooltipDiagnostics", "nativeUnreadable", self.nativeUnreadable)
    config:SetSectionEntry("tooltipDiagnostics", "presentations", self.presentationCount)
    config:SetSectionEntry("tooltipDiagnostics", "lastStyle", self.lastStyle or "none")
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
        nativeUnreadable = self.nativeUnreadable,
        currentUnit = self.lastUnitKey,
        style = self.lastStyle,
        replacingNative = self.replacingNative,
        refreshCount = self.refreshCount,
        labelReads = self.labelReads,
        lastSeenLabel = self.lastSeenLabel,
        patternsResolved = patterns.patternsResolved or 0,
        patternsExpected = patterns.patternsExpected or 0,
        fadeHold = Client.GetEntityTooltipFadeHold(),
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
end

local function ResetHover(module)
    module.lastUnitKey = nil
    module.lastQuestStamp = nil
    module.lastRespawnStamp = nil
    module.lastStyle = nil
    module.lastNativeStamp = nil
    module.nativeLines = nil
    module.pendingNativeStamp = nil
    module.pendingNativePolls = 0
    module.emptyPolls = 0
    module.suspendedForNativeFade = false
    HidePanels(module)
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

-- The native rows arrive exactly as the client rendered them, colour escapes
-- included, because the combined tooltip reprints them and those escapes carry
-- the colour. Identity, though, is compared against
-- Client.GetGameTooltipUnitLabel, which strips them. UQ.NameKey keeps letters
-- and digits and drops punctuation, so an escape survives it as text: a name
-- line reading "|cff00ff00Kobold Vermin|r" keys as "cff00ff00koboldverminr"
-- and can never equal the stripped label's "koboldvermin". The row set was
-- then thrown away as belonging to something else -- for the whole hover, not
-- for a frame -- which is what used to put a second box on screen.
local function PlainRowText(line)
    local text = line and (line.text or line.left)
    if type(text) ~= "string" then
        return nil
    end
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    return text
end

-- True when a row after the name carries the given level as a whole number.
-- The level row's wording is localized, its digits are not. An unknown level
-- (nil) never judges the rows.
local function RowsShowLevel(lines, level)
    if type(level) ~= "number" then
        return true
    end
    local index = 2
    local total = table.getn(lines or {})
    while index <= total do
        local line = lines[index]
        local texts = { PlainRowText(line), PlainRowText({ text = line.right }) }
        local slot = 1
        while slot <= 2 do
            if texts[slot] then
                for digits in string.gfind(texts[slot], "%d+") do
                    if tonumber(digits) == level then
                        return true
                    end
                end
            end
            slot = slot + 1
        end
        index = index + 1
    end
    return false
end

-- A rebuild can publish only a prefix of the old rows. Keep the last complete
-- snapshot until changed content repeats on three driver polls. OnShow is an
-- accelerator only and cannot consume that grace period in a burst. An exact
-- extension of the old snapshot can be displayed immediately.
local function StableNativeLines(module, unitKey, unitLevel, lines, fromShow)
    if lines and UQ.NameKey(PlainRowText(lines[1])) ~= unitKey then
        lines = nil
    end
    local previous = module.lastUnitKey == unitKey and module.nativeLines or nil
    -- Spawns sharing a name share one unitKey, so the held snapshot can carry
    -- another spawn's level row (or a rebuild that renamed row one before its
    -- level row). Rows showing the live mouseover level replace a snapshot
    -- that does not show it at once, without the stability grace.
    if lines and previous and RowsShowLevel(lines, unitLevel)
            and not RowsShowLevel(previous, unitLevel) then
        previous = nil
    end
    local stamp = NativeStamp(lines)
    if previous and stamp ~= NativeStamp(previous) then
        local extends = lines and table.getn(lines) > table.getn(previous)
        local index = 1
        while extends and index <= table.getn(previous) do
            if NativeStamp({ lines[index] }) ~= NativeStamp({ previous[index] }) then
                extends = false
            end
            index = index + 1
        end
        if not extends then
            if module.pendingNativeStamp ~= stamp then
                module.pendingNativeStamp = stamp
                module.pendingNativePolls = 0
            end
            if not fromShow then
                module.pendingNativePolls = module.pendingNativePolls + 1
            end
            if not lines or module.pendingNativePolls < NATIVE_STABLE_POLLS then
                module.deferredNativeReads = module.deferredNativeReads + 1
                return previous
            end
        end
    end
    module.pendingNativeStamp = nil
    module.pendingNativePolls = 0
    return lines
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

function EntityTooltip:Refresh(fromShow)
    self.refreshCount = self.refreshCount + 1

    -- GameTooltip is also the surface this addon paints its own quest
    -- tooltips on (a minimap quest pin, a tracker row -- see
    -- Client.ShowGameTooltip). Those already carry the quest's objectives
    -- from the log, and their first line is the quest title, which for a
    -- collect quest is commonly the collected item's own name: read back
    -- as an entity identity it matches that very objective and prints it
    -- a second time. Stand down entirely while the tooltip is ours.
    if Client.IsGameTooltipAddonOwned() then
        ResetHover(self)
        return
    end

    -- Identity comes from the tooltip's own rendered first line, not
    -- UnitName("mouseover") -- see Client.GetGameTooltipUnitLabel for why.
    local unitLabel, nativeShown = Client.GetGameTooltipUnitLabel()
    local unitKey = UQ.NameKey(unitLabel)

    -- Cursor-follow world objects can alternate GameTooltip between the cursor
    -- anchor and its native UIParent anchor every rendered frame (tooltipdupe
    -- v4, Doom Weed). A replacement cannot cover both positions without a
    -- screen-sized mask. Keep the one native tooltip for that measured case;
    -- actual mouseover units retain the combined tooltip in both cursor modes.
    if unitKey and Client.IsWorldTooltipCursorFollowEnabled() == true
            and not Client.UnitExists("mouseover") then
        -- Mouse-out clears the mouseover unit before GameTooltip clears the
        -- NPC name it is fading. If this is still the replacement already on
        -- screen, that stale name is the END of an NPC hover, not a newly
        -- hovered world object. Keep it for SyncFade's 0.7-second hold. A new
        -- or changed key with no mouseover unit remains the measured
        -- cursor-follow world-object case and keeps the native tooltip alone.
        if fromShow or not self.replacingNative or self.lastUnitKey ~= unitKey then
            ResetHover(self)
            return
        end
    end

    -- Any translucent cover reveals the native tooltip fading underneath it.
    -- SyncFade therefore keeps the owned replacement opaque for 0.7 seconds
    -- after mouse-out. IsShown can turn false before the last native pixels
    -- leave the renderer, so it only starts the hold timer. Do not
    -- put the replacement straight back on the next poll;
    -- a new hover (including the same subject) restores alpha 1 and resumes it.
    if self.suspendedForNativeFade then
        if not unitKey or Client.IsNativeEntityTooltipFullyOpaque() ~= true then
            return
        end
        self.suspendedForNativeFade = false
        self.lastNativeStamp = nil
    end

    if not unitKey and nativeShown ~= false and self.panel then
        self.pendingNativeStamp = nil
        self.pendingNativePolls = 0
        -- A shown native tooltip can clear its label before its fade finishes.
        -- Keep covering it until it actually hides, as the host's world
        -- tooltip does. The bounded timeout is only for unknown visibility.
        if nativeShown == true then
            self.emptyPolls = 0
        elseif not fromShow then
            self.emptyPolls = self.emptyPolls + 1
        end
        if self.emptyPolls < EMPTY_POLL_LIMIT then
            self.heldEmptyReads = self.heldEmptyReads + 1
            if self.replacingNative then
                Client.CoverNativeEntityTooltip(self.panel)
            end
            return
        end
    elseif unitKey then
        self.emptyPolls = 0
    end

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
        if self.panel then
            self:RecordSeen()
        end
        -- GameTooltip can report hidden before its final fade pixels disappear.
        -- That must not make this slower poll remove the custom tooltip; the
        -- custom presentation owns its full 0.7-second mouse-out delay.
        if nativeShown == false and self.replacingNative and self.panel then
            local _, released = Client.SyncEntityTooltipFade(self.panel)
            if not released and Client.IsEntityTooltipFadeHolding(self.panel) then
                return
            end
        end
        ResetHover(self)
        return
    end

    local matcher = UQ:GetModule("ObjectiveMatch")
    local matcherStatus = matcher and matcher:GetStatus() or {}
    local questStamp = matcherStatus.questStamp or 0
    local respawnMinimum, respawnMaximum, respawnReady, respawnRevision
    local config = UQ:GetModule("Config")
    if not config or config:Get("tooltipRespawnTimers") ~= false then
        local database = UQ:GetModule("Database")
        if database then
            respawnMinimum, respawnMaximum, respawnReady, respawnRevision =
                database:GetEntityRespawn(unitKey)
        end
    end
    local respawnStamp = tostring(respawnMinimum) .. ":" .. tostring(respawnMaximum)
        .. ":" .. tostring(respawnReady) .. ":" .. tostring(respawnRevision)
    local style = Client.GetEntityTooltipStyle()
    -- Every row the native tooltip currently shows, so the replacement can
    -- carry them itself. nil means the rows could not be read, which is the
    -- only case where the native tooltip is left visible.
    local nativeLines = StableNativeLines(self, unitKey,
        Client.GetUnitLevel("mouseover"), Client.GetGameTooltipLines(), fromShow)
    local nativeStamp = NativeStamp(nativeLines)
    -- Reassert only owned cover geometry during native rebuilds. Never write
    -- alpha to GameTooltip or any of its (possibly another addon's) regions.
    if self.lastUnitKey == unitKey and self.lastQuestStamp == questStamp
            and self.lastRespawnStamp == respawnStamp
            and self.lastStyle == style and self.lastNativeStamp == nativeStamp then
        if self.replacingNative then
            Client.CoverNativeEntityTooltip(self.panel)
        end
        return
    end
    self.lastUnitKey = unitKey
    self.lastQuestStamp = questStamp
    self.lastRespawnStamp = respawnStamp
    self.lastStyle = style
    self.lastNativeStamp = nativeStamp
    self.nativeLines = nativeLines

    local lines, direct, viaDatabase = self:BuildLines(
        unitKey, respawnMinimum, respawnMaximum)
    if not lines then
        HidePanels(self)
        return
    end

    if direct ~= nil or viaDatabase ~= nil then
        self:RecordMatch(direct, viaDatabase)
    end

    -- No native rows to reprint means no combined tooltip, and a combined
    -- tooltip is the only one this module will draw. Presenting the quest rows
    -- on their own would put a second box beside the tooltip they belong to.
    -- StableNativeLines retains the last complete snapshot, so this normally
    -- waits a single 0.1s poll at the start of a hover; a subject whose rows
    -- never read back simply keeps its plain native tooltip and is counted
    -- here, where /uq tooltip and SavedVariables can find it.
    if not nativeLines then
        self.nativeUnreadable = self.nativeUnreadable + 1
        HidePanels(self)
        self:RecordSeen()
        return
    end

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
    if panel then
        shown = Client.ShowEntityTooltipPanel(panel,
            CombinedLines(nativeLines, unitKey, lines))
        self.replacingNative = shown
    end

    if not panel or not shown then
        -- Creation can fail transiently during UI startup. Do not cache that
        -- failure as a completed presentation for this hover.
        ResetHover(self)
        self:RecordPresentationFailure()
    else
        self.suspendedForNativeFade = false
        self.presentationCount = self.presentationCount + 1
    end
    self:RecordSeen()
end

-- Fade ----------------------------------------------------------------------

-- The replacement stays fully opaque over the native fade and hides with the
-- native frame at the end.
--
-- This per-frame sync keeps the replacement opaque for the runtime-selected
-- delay after the first native fade/hidden signal, including frames after
-- GameTooltip:IsShown() has already become false.
function EntityTooltip:SyncFade()
    local panel = self.panel
    if not panel then
        return
    end
    local _, released = Client.SyncEntityTooltipFade(panel)
    if released then
        self.replacingNative = false
        self.suspendedForNativeFade = true
    end
end

-- Lifecycle -----------------------------------------------------------------

function EntityTooltip:OnEnable()
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("tooltip.entity", POLL_INTERVAL, function()
            EntityTooltip:Refresh()
        end)
        -- Every tick, deliberately: see SyncFade. It returns immediately while
        -- no replacement is on screen, and writes nothing at all on a frame
        -- where the opacity has not changed -- no allocation and no name
        -- lookup, so the driver's stall census has nothing to charge it with.
        driver:Schedule("tooltip.fade", 0, function()
            EntityTooltip:SyncFade()
        end)
        -- Refresh runs synchronously here too, not just via driver:Wake, so the
        -- combined tooltip is ready with the native one. The poll above remains
        -- the correctness guarantee if this never fires.
        Client.HookGameTooltipShow(function()
            EntityTooltip:Refresh(true)
        end)
    end
end
