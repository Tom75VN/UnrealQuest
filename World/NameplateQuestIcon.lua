--[[
UnrealQuest / World/NameplateQuestIcon.lua

The quest's numbered badge to the right of a creature's nameplate, while an
unfinished objective of that quest still wants the creature. The number is the
same one the tracker row and the world-map area carry -- the quest's position
in QuestState's unfiltered log order -- so the three always agree. A creature
several quests want gets one badge per quest, lowest number first, up to
MAX_BADGES.

Where the plates come from: world.nameplates_are_not_lua_widgets, superseded
2026-10-19 -- with the client's plates switched on they are WorldFrame
children, discovered by watching the child count grow, as in Vanilla. With
plates off there are none and nothing is drawn. Which children are plates and
where a badge may hang is Client's (Compatibility/ClientAPI.lua, "Quest
numbers on nameplates"); whether a creature is wanted is ObjectiveMatch's.

Nothing here writes to a native plate, and no event is relied on: one poll on
the shared driver finds new plates and refreshes the badges.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local NameplateQuestIcon = UQ:NewModule("NameplateQuestIcon")

local POLL_INTERVAL = 0.2
local MAX_BADGES = 3
-- Plates are never destroyed, so this bounds the plates remembered, not the
-- ones on screen at once. A WorldFrame child past it is still inspected and
-- simply not tracked.
local MAX_PLATES = 200
-- Per-pass high-water marks, then session totals, persisted by Record.
local DIAGNOSTIC_KEYS = { "shown", "onOverlay", "onPlate", "waiting", "duplicates", "hiddenAnchor" }
local DIAGNOSTIC_TOTALS = { "externalHides", "nameChanges", "uuiFlips" }
local SHAPE_INTERVAL = 2

NameplateQuestIcon.plates = {}
NameplateQuestIcon.known = {}
-- native plate -> its record, whichever way the plate was found
NameplateQuestIcon.tracked = {}
-- native plate -> unrealUI overlay (Client.CollectUnrealUINameplateOverlays)
NameplateQuestIcon.overlays = {}
NameplateQuestIcon.overlayCount = 0
NameplateQuestIcon.waitingShape = nil
NameplateQuestIcon.scanned = 0
NameplateQuestIcon.badgeCount = 0
NameplateQuestIcon.numbers = {}
NameplateQuestIcon.numberStamp = nil
NameplateQuestIcon.shown = 0
NameplateQuestIcon.onOverlay = 0
NameplateQuestIcon.onPlate = 0
NameplateQuestIcon.waiting = 0
NameplateQuestIcon.duplicates = 0
NameplateQuestIcon.hiddenAnchor = 0
NameplateQuestIcon.uuiActive = false
-- Session totals: a badge something else hid after this module showed it,
-- and a plate whose name text changed under it.
NameplateQuestIcon.externalHides = 0
NameplateQuestIcon.nameChanges = 0
NameplateQuestIcon.uuiFlips = 0
NameplateQuestIcon.shownNow = {}
NameplateQuestIcon.shownShape = nil
NameplateQuestIcon.lastKey = nil
NameplateQuestIcon.best = {}

function NameplateQuestIcon:IsEnabled()
    local config = UQ:GetModule("Config")
    return not (config and config:Get("nameplateQuestIcon") == false)
end

-- New WorldFrame children only: each is inspected once, when it appears.
function NameplateQuestIcon:Scan()
    local worldFrame = Client.GetWorldFrame()
    local count = worldFrame and Client.GetChildCount(worldFrame)
    if not count then
        return
    end
    if count < self.scanned then
        self.scanned = 0
    end
    if count == self.scanned then
        return
    end
    local children = Client.GetChildList(worldFrame)
    if not children then
        return
    end
    local index = self.scanned + 1
    while index <= count do
        local child = children[index]
        if child and not self.known[child] then
            self.known[child] = true
            if table.getn(self.plates) < MAX_PLATES then
                local fonts = Client.GetNameplateFontStrings(child)
                if fonts then
                    self:Track(child, fonts, "walk")
                end
            end
        end
        index = index + 1
    end
    self.scanned = count
end

function NameplateQuestIcon:Track(frame, fonts, source)
    if self.tracked[frame] or table.getn(self.plates) >= MAX_PLATES then
        return
    end
    local record = { frame = frame, fonts = fonts, badges = {}, source = source }
    self.tracked[frame] = record
    table.insert(self.plates, record)
end

-- unrealUI's overlays name the plates it adopted, which also covers a plate
-- the WorldFrame walk above did not recognise.
function NameplateQuestIcon:CollectOverlays()
    local fresh = Client.CollectUnrealUINameplateOverlays(self.overlays)
    if not fresh then
        return
    end
    local index = 1
    local total = table.getn(fresh)
    while index <= total do
        local overlay = fresh[index]
        self.overlayCount = self.overlayCount + 1
        local fonts = Client.GetNameplateOverlayFonts(overlay)
        if fonts then
            self.known[overlay.plate] = true
            self:Track(overlay.plate, fonts, "overlay")
        end
        index = index + 1
    end
end

-- titleKey -> number, rebuilt only when the quest log changed.
function NameplateQuestIcon:Numbers(matcher)
    local stamp = matcher and matcher.questStamp
    if stamp ~= nil and stamp == self.numberStamp then
        return self.numbers
    end
    local numbers = {}
    local state = UQ:GetModule("QuestState")
    local quests = state and state:GetOrderedQuests() or {}
    local index = 1
    local total = table.getn(quests)
    while index <= total do
        local quest = quests[index]
        if quest and quest.titleKey then
            numbers[quest.titleKey] = index
        end
        index = index + 1
    end
    self.numbers = numbers
    self.numberStamp = stamp
    return numbers
end

-- { { number = n, titleKey = key }, ... } for the unfinished quests that want
-- this creature, lowest number first, or nil.
function NameplateQuestIcon:QuestsFor(unitKey, matcher, numbers)
    local results = unitKey and matcher and matcher:FindForUnit(unitKey)
    if not results then
        return nil
    end
    local wanted = {}
    local seen = {}
    local index = 1
    local total = table.getn(results)
    while index <= total do
        local result = results[index]
        local key = result.quest and result.quest.titleKey
        local number = key and numbers[key]
        if not result.finished and number and not seen[key] then
            seen[key] = true
            table.insert(wanted, { number = number, titleKey = key })
        end
        index = index + 1
    end
    if table.getn(wanted) == 0 then
        return nil
    end
    table.sort(wanted, function(a, b) return a.number < b.number end)
    return wanted
end

function NameplateQuestIcon:HideBadges(plate, from)
    local index = from or 1
    local total = table.getn(plate.badges)
    while index <= total do
        Client.HideNameplateQuestBadge(plate.badges[index])
        index = index + 1
    end
end

-- A badge that could not be built is not retried: CreateFrame failing once
-- will fail every pass, and each try would burn a global name.
function NameplateQuestIcon:Badge(plate, slot)
    local badge = plate.badges[slot]
    if not badge and not self.buildFailed then
        self.badgeCount = self.badgeCount + 1
        badge = Client.CreateNameplateQuestBadge(self.badgeCount)
        if badge then
            plate.badges[slot] = badge
        else
            self.buildFailed = true
        end
    end
    return badge
end

function NameplateQuestIcon:RefreshPlate(plate, matcher, numbers, mainQuest, uiScale, claimed)
    if not Client.IsNameplateShown(plate.frame) then
        self:HideBadges(plate)
        return
    end
    -- The raw text first: NameKey allocates, and a plate keeps its unit for
    -- many passes.
    local name = Client.ReadNameplateName(plate.fonts)
    if name ~= plate.name or plate.stamp ~= self.numberStamp then
        if name ~= plate.name and plate.name ~= nil then
            self.nameChanges = self.nameChanges + 1
        end
        plate.name = name
        plate.stamp = self.numberStamp
        local unitKey = UQ.NameKey(name)
        plate.wanted = self:QuestsFor(unitKey, matcher, numbers)
        if plate.wanted then
            self.lastKey = unitKey
        end
    end
    local wanted = plate.wanted
    if not wanted then
        self:HideBadges(plate)
        return
    end

    -- While unrealUI's plates are on, its own overlay registry is the only
    -- source. 2026-10-19 in game: the same native plate came back from
    -- WorldFrame:GetChildren() and from overlay.plate as two different
    -- objects, so it was tracked twice; the WorldFrame copy's badge sat on a
    -- child unrealUI mutes and blinked under the plate (47 outside hides).
    if not plate.overlay then
        local overlay = self.overlays[plate.frame]
        if overlay then
            plate.overlay, plate.overlayAnchor = overlay, Client.GetNameplateOverlayAnchor(overlay)
        elseif not self.uuiActive then
            plate.overlay, plate.overlayAnchor = Client.FindNameplateOverlay(plate.frame)
        end
    end
    local host, anchor, scale = plate.overlay, plate.overlayAnchor, 1
    local size = nil
    if host and plate.overlay and not (Client.IsNameplateShown(host)
            and Client.IsNameplateShown(anchor)) then
        -- 2026-10-19 in game: unrealUI kept a second overlay for the same
        -- creature (UnrealUINamePlate1 beside UnrealUINamePlate2) that draws
        -- no bar, and the badge hung on it floated under the real plate. A
        -- badge goes only beside a health bar that is actually drawn.
        self.hiddenAnchor = self.hiddenAnchor + 1
        self:HideBadges(plate)
        return
    elseif host and claimed[host] then
        -- Another record of this same plate already drew here this pass.
        self.duplicates = self.duplicates + 1
        self:HideBadges(plate)
        return
    elseif host then
        claimed[host] = true
        self.onOverlay = self.onOverlay + 1
        -- Top and bottom level with the health bar it sits beside; an
        -- overlay without one keeps the default size.
        if anchor ~= host then
            size = Client.GetNameplateQuestBadgeSize(anchor)
        end
    elseif self.uuiActive then
        -- unrealUI mutes every direct child of a plate it adopts on its 0.1s
        -- tick, so a badge hung on such a plate blinks: shown here, hidden
        -- there (seen in game 2026-10-19). With its plates on, the badge goes
        -- on its overlay or nowhere.
        self.waiting = self.waiting + 1
        if not plate.described then
            plate.described = true
            self.waitingShape = Client.DescribeNameplate(plate.frame)
        end
        self:HideBadges(plate)
        return
    else
        self.onPlate = self.onPlate + 1
        -- A WorldFrame child is not under UIParent's scale; unrealUI scales its
        -- overlay the same way so plate art reads in UI units.
        host, anchor, scale = plate.frame, plate.frame, uiScale
    end

    local total = table.getn(wanted)
    if total > MAX_BADGES then
        total = MAX_BADGES
    end
    local slot = 1
    while slot <= total do
        local entry = wanted[slot]
        local followed = mainQuest and mainQuest:IsMain(entry.titleKey) and true or false
        if Client.WasNameplateQuestBadgeHidden(plate.badges[slot]) then
            self.externalHides = self.externalHides + 1
        end
        local badge = self:Badge(plate, slot)
        if Client.ShowNameplateQuestBadge(badge, host, anchor, slot,
                entry.number, followed, scale, size) then
            self.shown = self.shown + 1
            if table.getn(self.shownNow) < 4 then
                table.insert(self.shownNow, tostring(plate.source) .. ":"
                    .. Client.DescribeNameplateQuestBadge(badge))
            end
        end
        slot = slot + 1
    end
    self:HideBadges(plate, total + 1)
end

function NameplateQuestIcon:Refresh()
    local plates = self.plates
    local total = table.getn(plates)
    local index = 1
    if not self:IsEnabled() then
        while index <= total do
            self:HideBadges(plates[index])
            index = index + 1
        end
        self.shown = 0
        return
    end

    local active = Client.IsUnrealUINameplatesActive()
    if active ~= self.uuiActive then
        self.uuiFlips = self.uuiFlips + 1
    end
    self.uuiActive = active
    self.shownNow = {}
    if self.uuiActive then
        self:CollectOverlays()
    end
    self:Scan()
    total = table.getn(plates)
    self.shown = 0
    self.onOverlay = 0
    self.onPlate = 0
    self.waiting = 0
    self.duplicates = 0
    self.hiddenAnchor = 0
    if total > 0 then
        local matcher = UQ:GetModule("ObjectiveMatch")
        local numbers = self:Numbers(matcher)
        local mainQuest = UQ:GetModule("MainQuest")
        local uiScale = Client.GetUIParentScale()
        local claimed = {}
        while index <= total do
            self:RefreshPlate(plates[index], matcher, numbers, mainQuest, uiScale, claimed)
            index = index + 1
        end
    end
    self:Record()
end

function NameplateQuestIcon:GetStatus()
    return {
        enabled = self:IsEnabled(),
        plates = table.getn(self.plates),
        shown = self.shown,
        onOverlay = self.onOverlay,
        onPlate = self.onPlate,
        waiting = self.waiting,
        externalHides = self.externalHides,
        nameChanges = self.nameChanges,
        uuiActive = self.uuiActive and true or false,
        uuiOverlays = self.overlayCount,
        lastKey = self.lastKey,
    }
end

-- Persisted so an in-game run is read from SavedVariables, not a screenshot.
-- Written only when a counter changes; the high-water marks keep what a
-- short-lived plate did after it scrolled away.
function NameplateQuestIcon:Record()
    local config = UQ:GetModule("Config")
    if not config then
        return
    end
    local best = self.best
    local changed = false
    local keys = DIAGNOSTIC_KEYS
    local index = 1
    local total = table.getn(keys)
    while index <= total do
        local key = keys[index]
        local value = self[key] or 0
        if value > (best[key] or 0) then
            best[key] = value
            changed = true
        end
        index = index + 1
    end
    index = 1
    while index <= table.getn(DIAGNOSTIC_TOTALS) do
        local key = DIAGNOSTIC_TOTALS[index]
        if self[key] ~= best[key] then
            best[key] = self[key]
            changed = true
        end
        index = index + 1
    end
    -- Positions move with the camera; sampled every SHAPE_INTERVAL seconds so
    -- the readout is not rewritten on every pass.
    local shownCount = table.getn(self.shownNow)
    local now = Client.Now() or 0
    if shownCount > 0 and now >= (self.nextShapeAt or 0) then
        self.nextShapeAt = now + SHAPE_INTERVAL
        local text = self.shownNow[1]
        local i = 2
        while i <= shownCount do
            text = text .. " | " .. self.shownNow[i]
            i = i + 1
        end
        self.shownShape = text
    end
    local plates = table.getn(self.plates)
    if plates ~= best.plates or self.shownShape ~= best.shownShape or (self.uuiActive and true or false) ~= best.uuiActive
        or self.lastKey ~= best.lastKey or self.overlayCount ~= best.uuiOverlays
        or self.waitingShape ~= best.waitingShape then
        best.plates = plates
        best.uuiActive = self.uuiActive and true or false
        best.lastKey = self.lastKey
        best.uuiOverlays = self.overlayCount
        best.waitingShape = self.waitingShape
        best.shownShape = self.shownShape
        changed = true
    end
    if not changed then
        return
    end
    config:SetSectionEntry("nameplateQuestIconDiagnostics", "plates", best.plates)
    config:SetSectionEntry("nameplateQuestIconDiagnostics", "uuiActive", best.uuiActive)
    config:SetSectionEntry("nameplateQuestIconDiagnostics", "lastKey", best.lastKey)
    config:SetSectionEntry("nameplateQuestIconDiagnostics", "uuiOverlays", best.uuiOverlays)
    -- A wanted plate unrealUI's plates were on for but no overlay was found:
    -- its name:type and its children's, the open shape question.
    config:SetSectionEntry("nameplateQuestIconDiagnostics", "waitingShape", best.waitingShape)
    -- The last pass that drew anything: source:badge>host/anchor@left,bottom.
    config:SetSectionEntry("nameplateQuestIconDiagnostics", "shownShape", best.shownShape)
    index = 1
    while index <= total do
        config:SetSectionEntry("nameplateQuestIconDiagnostics", "max_" .. keys[index], best[keys[index]])
        index = index + 1
    end
    index = 1
    while index <= table.getn(DIAGNOSTIC_TOTALS) do
        local key = DIAGNOSTIC_TOTALS[index]
        config:SetSectionEntry("nameplateQuestIconDiagnostics", key, best[key])
        index = index + 1
    end
end

function NameplateQuestIcon:OnEnable()
    UQ:DeclareCapability("nameplateQuestIcon", "unverified",
        "the quest number beside a creature's nameplate. Plates are WorldFrame children while the "
        .. "client's plates are switched on (world.nameplates_are_not_lua_widgets, superseded "
        .. "2026-10-19, user-confirmed through unrealUI's overlay); the badge drawn beside one has not "
        .. "been seen in game yet. The plate's own shape is unmeasured, so plates are recognised by "
        .. "structure with the measured false positives denied by name")
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("world.nameplatequesticon", POLL_INTERVAL, function()
        NameplateQuestIcon:Refresh()
    end)
end
