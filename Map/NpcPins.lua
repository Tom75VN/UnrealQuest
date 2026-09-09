--[[
UnrealQuest / Map/NpcPins.lua

A compact multi-select menu for nearby service NPCs and world nodes, opened
from the quest tracker's spyglass. Selected categories are drawn as exact
points on both the current-zone world map and the minimap. `Data/Database.lua`
is the only layer that reads meta.lua and trainers.lua; this module only
consumes normalized service locations.

The menu holds two groups divided by a one-pixel rule: the twelve service
categories, then dungeon/raid entrances plus five world-node categories
(chests, herbs, mines, fishing pools, rare mobs). Nodes are far denser than
services -- hundreds per zone -- so they are only read out of the database
while checked, and the pin budget is split per category.

The world map and minimap reuse their already-confirmed pooled pin contracts.
Minimap points outside the current view are hidden rather than clamped: service
locations are exact coordinates, and collapsing many vendors or trainers onto
one edge point would invent a location that is not in the database.

The TRACKED CREATURE is the one exception, and the exception is narrow enough
not to weaken the rule. Tracking is single-select and deliberate: the player
named one creature and is being pointed at it by an arrow (HUD/MobNavigator.lua),
so its spawns are not a field of incidental locations the layer happens to know
about -- they are the thing being navigated to, and a mark that vanishes at the
rim is exactly the information the player asked for going missing. A clamped
pin keeps its true bearing and says "further than this" with a faded alpha, the
same contract the quest layer's givers and turn-ins already use on this
surface.

It is clamped UNCONDITIONALLY -- `minimapPinsClampEdge` does not reach it. That
switch answers "should the incidental markers around me pile onto the rim or
stay out of the way?", and turning it off is a request for a quieter minimap.
The tracked creature is not part of that crowd: it is one pin, asked for by
name, and the whole reason it was tracked is to be led to it. Hiding it would
answer a question the player did not ask.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local NpcPins = UQ:NewModule("NpcPins")

local REFRESH_INTERVAL = 0.1
local WORLD_REFRESH_INTERVAL = 0.25
local WORLD_INDEX_OFFSET = 6000
local MINIMAP_INDEX_OFFSET = 10000
local WORLD_PIN_SIZE = 15
local MINIMAP_PIN_SIZE = 14

-- The review collection has been promoted into bundled data. Keep its code in
-- place for another review pass, but register no right-click token and show no
-- tooltip hint while the temporary surface is disabled.
local REVIEW_REMOVAL_ENABLED = false

-- Grows a hovered Rare/Elite/Boss pin so the one under the mouse reads as
-- distinct from the rest of the row, the same 1.5x the quest layer's giver
-- and turn-in markers use (Map/WorldMapPins.lua, GIVER_TURNIN_HOVER_SCALE).
-- Service and node icons do not grow: the request this answers was about the
-- mob icons specifically, and there is no reason yet to widen it.
local MOB_HOVER_SCALE = 1.5
local MOB_HOVER_DURATION = 0.16
-- Gathering nodes draw at half size on both maps. A service is one point the
-- player is looking for; herbs and veins come in dense fields, and at the
-- service size those fields cover the terrain they are supposed to sit on.
-- The pools are shared, so the size is applied on every draw rather than once
-- at creation -- a pin that carried a node last frame may carry a vendor next.
local NODE_WORLD_PIN_SIZE = WORLD_PIN_SIZE / 2
local NODE_MINIMAP_PIN_SIZE = MINIMAP_PIN_SIZE / 2
local MINIMAP_MARGIN = 2
-- The ring around the one tracked-mob spawn HUD/MobNavigator.lua's arrow is
-- currently aiming at. Same artwork, same padding and the same -1 level boost
-- as the followed quest's dot rim on both maps (Map/WorldMapPins.lua,
-- Map/MinimapPins.lua), because it answers the same question -- "which of
-- these identical marks is the one being navigated to?" -- and answering it
-- with a second visual language would make both harder to learn.
--
-- A tracked creature commonly has a dozen recorded spawns in one zone, drawn
-- as a dozen identical accent dots. Without this the player can see where the
-- arrow points but not which dot it chose.
local NAV_MARK_PADDING = 6
local NAV_MARK_LEVEL_BOOST = -1
-- What a clamped tracked pin keeps of its opacity. A pin on the rim means
-- "further than this rather than here", and the fade is what says so -- the
-- same value and the same reason as Map/MinimapPins.lua's EDGE_ALPHA.
local MINIMAP_EDGE_ALPHA = 0.55
local MAX_PINS = 480
-- World nodes come in the hundreds per zone where services come in dozens, so
-- one global ceiling would let the first category alphabetically consume the
-- whole budget and silently erase the rest of the selection. The budget is
-- therefore split evenly across whatever is checked, with a floor so a large
-- selection still shows something of each.
local MIN_PINS_PER_CATEGORY = 60

-- `labelKey` rather than a label: this table is built when the file loads,
-- which is before Core/Locale.lua has resolved the language, so a translated
-- string baked in here would be English for the whole session. Resolved at use
-- in GetMenuEntries and TooltipLines.
local CATEGORIES = {
    { key = "trainer", setting = "npcCategoryTrainer", labelKey = "NPC_CATEGORY_TRAINER",
      icon = "trainers-icon",
      red = 0.74, green = 0.36, blue = 1.00 },
    { key = "auctioneer", setting = "npcCategoryAuctioneer", labelKey = "NPC_CATEGORY_AUCTIONEER",
      icon = "auctioneer",
      red = 1.00, green = 0.73, blue = 0.10 },
    { key = "banker", setting = "npcCategoryBanker", labelKey = "NPC_CATEGORY_BANKER",
      icon = "banker",
      red = 0.74, green = 0.55, blue = 0.24 },
    { key = "battlemaster", setting = "npcCategoryBattlemaster", labelKey = "NPC_CATEGORY_BATTLEMASTER",
      icon = "battlemaster",
      red = 0.92, green = 0.20, blue = 0.18 },
    { key = "flight", setting = "npcCategoryFlight", labelKey = "NPC_CATEGORY_FLIGHT",
      icon = "flight",
      red = 0.78, green = 0.78, blue = 0.88 },
    { key = "innkeeper", setting = "npcCategoryInnkeeper", labelKey = "NPC_CATEGORY_INNKEEPER",
      icon = "innkeeper",
      red = 0.20, green = 0.78, blue = 0.92 },
    { key = "mailbox", setting = "npcCategoryMailbox", labelKey = "NPC_CATEGORY_MAILBOX",
      icon = "mailbox",
      red = 0.95, green = 0.95, blue = 0.95 },
    { key = "meetingstone", setting = "npcCategoryMeetingstone", labelKey = "NPC_CATEGORY_MEETINGSTONE",
      icon = "meetingstone",
      red = 0.10, green = 0.72, blue = 1.00 },
    { key = "repair", setting = "npcCategoryRepair", labelKey = "NPC_CATEGORY_REPAIR",
      icon = "repair",
      red = 0.62, green = 0.66, blue = 0.72 },
    { key = "spirithealer", setting = "npcCategorySpirithealer", labelKey = "NPC_CATEGORY_SPIRITHEALER",
      icon = "spirithealer",
      red = 0.34, green = 0.62, blue = 1.00 },
    { key = "stablemaster", setting = "npcCategoryStablemaster", labelKey = "NPC_CATEGORY_STABLEMASTER",
      icon = "stablemaster",
      red = 0.67, green = 0.42, blue = 0.20 },
    { key = "vendor", setting = "npcCategoryVendor", labelKey = "NPC_CATEGORY_VENDOR",
      icon = "vendor",
      red = 1.00, green = 0.52, blue = 0.12 },

    -- Map locations. `separator` draws the one-pixel rule that divides them
    -- from the service rows above. Instance pins choose dungeon or raid art
    -- per record; `detail` names what a node relation value means.
    { key = "instances", setting = "npcCategoryInstances", labelKey = "NPC_CATEGORY_INSTANCES",
      icon = "dungeon-entrance", separator = true,
      red = 0.45, green = 0.75, blue = 1.00 },
    { key = "chests", setting = "npcCategoryChests", labelKey = "NPC_CATEGORY_CHESTS",
      icon = "chests",
      red = 1.00, green = 0.82, blue = 0.35 },
    { key = "herbs", setting = "npcCategoryHerbs", labelKey = "NPC_CATEGORY_HERBS",
      icon = "herbs", detail = "skill", small = true,
      red = 0.40, green = 0.85, blue = 0.35 },
    { key = "mines", setting = "npcCategoryMines", labelKey = "NPC_CATEGORY_MINES",
      icon = "mines", detail = "skill", small = true,
      red = 0.80, green = 0.62, blue = 0.40 },
    { key = "fish", setting = "npcCategoryFish", labelKey = "NPC_CATEGORY_FISH",
      icon = "fish",
      red = 0.35, green = 0.70, blue = 0.95 },
    { key = "rares", setting = "npcCategoryRares", labelKey = "NPC_CATEGORY_RARES",
      icon = "rare-mobs", detail = "level",
      red = 0.95, green = 0.85, blue = 0.20 },
}

-- A settings-selected creature is not another tracker-header category: each
-- unit is chosen by name and persisted independently. It still joins this
-- layer's target/pool machinery through one private presentation category.
-- No service icon is assigned, so tracked creatures use the ordinary coloured
-- objective dot rather than being misrepresented as rares or vendors.
local TRACKED_CATEGORY = {
    key = "tracked",
    labelKey = "NPC_CATEGORY_TRACKED_MOB",
    red = UQ.colors.accent[1],
    green = UQ.colors.accent[2],
    blue = UQ.colors.accent[3],
}

-- The Rare/Elite/Boss row is one category with three faces, so a pin says
-- which kind of creature it is without being hovered. The rank comes off the
-- unit record; a creature whose rank cannot be read keeps the row's own icon.
local RANK_ICONS = {
    [1] = "elite-mobs",     -- elite
    [2] = "elite-mobs",     -- rare elite
    [3] = "boss-mobs",      -- boss / world boss
    [4] = "rare-mobs",      -- rare
}

-- ...and the tooltip names the creature's OWN classification rather than the
-- row it arrived on. "Rare/Elite/Boss" is the name of a filter and tells the
-- player nothing about the thing under their cursor; "Rare Elite" does. KEYS,
-- not text: this table is built at file load, before Core/Locale.lua has
-- resolved the language.
local RANK_LABEL_KEYS = {
    [1] = "RARE_RANK_ELITE",
    [2] = "RARE_RANK_RARE_ELITE",
    [3] = "RARE_RANK_BOSS",
    [4] = "RARE_RANK_RARE",
}

local function RankLabelKey(location)
    if location.sourceType ~= "unit" then
        return nil
    end
    local database = UQ:GetModule("Database")
    local rank = database and database:GetUnitRank(location.sourceId)
    return rank and RANK_LABEL_KEYS[rank] or nil
end

-- A herb or a vein draws its own artwork rather than the category icon, so a
-- Peacebloom pin is recognizable as Peacebloom. `Data/NodeIcons.lua` maps the
-- object ID to a file under media/icons/<category>/; an object it does not
-- name -- Incendicite, Indurium, the Obsidian Chunks -- keeps the category
-- icon. Objects are looked up there; the one UNIT category with per-entity
-- artwork is Rare/Elite/Boss, which picks its face by rank above.
local function IconForLocation(location, category)
    if category.key == "instances" then
        if location.instanceType == 1 then
            return "raid-entrance"
        end
        return "dungeon-entrance"
    end
    if location.sourceType == "unit" then
        if category.key ~= "rares" then
            return category.icon
        end
        local database = UQ:GetModule("Database")
        local rank = database and database:GetUnitRank(location.sourceId)
        return (rank and RANK_ICONS[rank]) or category.icon
    end
    if type(UQ.nodeIcons) ~= "table" then
        return category.icon
    end
    local perObject = UQ.nodeIcons[location.category]
    local file = type(perObject) == "table" and perObject[location.sourceId]
    if type(file) ~= "string" then
        return category.icon
    end
    return location.category .. "\\" .. file
end

local CATEGORY_BY_KEY = {}
local categoryIndex = 1
while categoryIndex <= table.getn(CATEGORIES) do
    CATEGORY_BY_KEY[CATEGORIES[categoryIndex].key] = CATEGORIES[categoryIndex]
    categoryIndex = categoryIndex + 1
end
CATEGORY_BY_KEY.tracked = TRACKED_CATEGORY

NpcPins.worldPool = {}
NpcPins.minimapPool = {}
-- One ring per surface rather than a pool: exactly one spawn is aimed at.
NpcPins.worldNavMark = nil
NpcPins.minimapNavMark = nil
NpcPins.worldNavMarkVisible = false
NpcPins.minimapNavMarkVisible = false
-- Tracked pins currently resting on the minimap rim rather than at their own
-- position. Reported, never branched on.
NpcPins.minimapClamped = 0
NpcPins.targets = {}
-- The minimap's own set: it can only ever draw the player's zone, so it parts
-- company with self.targets whenever the world map is showing another one.
NpcPins.minimapTargets = {}
NpcPins.dirty = true
NpcPins.lastAreaId = nil
NpcPins.lastPlayerAreaId = nil
NpcPins.lastWorldDrawAt = nil
NpcPins.worldVisible = 0
NpcPins.minimapVisible = 0
NpcPins.playerClassId = nil
NpcPins.playerRaceId = nil
NpcPins.playerClassName = nil

-- The world-map Rare/Elite/Boss pin currently under the mouse, or nil. Read by
-- DrawWorldMap (which runs on a 0.25s timer regardless of hover) so a redraw
-- mid-hover cannot silently shrink the pin back to its base size.
NpcPins.hoveredMobPin = nil

-- Set while the quest layer is holding a hover focus, so every pin this
-- module draws fades behind the quest the player is pointing at. Nothing here
-- decides it: a service, node or rare pin belongs to no quest, so the whole
-- pool is unrelated to any of them and fades as a block. The two surfaces keep
-- their own flag because their hovers are independent -- the map's focus must
-- not fade the minimap, or the other way round.
-- Read by the draw passes as well as written by the setters, so a pin that
-- becomes visible mid-hover arrives already faded instead of at full opacity.
local FOCUS_DIM_ALPHA = 0.25
local FOCUS_FULL_ALPHA = 1
NpcPins.worldFocusDimmed = false
NpcPins.minimapFocusDimmed = false

local function Config()
    return UQ:GetModule("Config")
end

local function Database()
    return UQ:GetModule("Database")
end

local function MapContext()
    return UQ:GetModule("MapContext")
end

local function MinimapPins()
    return UQ:GetModule("MinimapPins")
end

local function MobNavigator()
    return UQ:GetModule("MobNavigator")
end

local function Setting(key)
    local config = Config()
    return config and config:Get(key)
end

local function Store(key, value)
    local config = Config()
    return config and config:Set(key, value)
end

-- Pulls a point back onto the minimap rim, keeping its bearing. The bearing is
-- the whole of what a clamped pin still says truthfully, so the offsets are
-- scaled rather than replaced. A point already inside, or exactly on the
-- player, is returned untouched: dividing by that distance is what would put a
-- pin at nan.
local function ClampToRim(offsetX, offsetY, distance, rim)
    if distance <= rim or distance <= 0 then
        return offsetX, offsetY, false
    end
    local scale = rim / distance
    return offsetX * scale, offsetY * scale, true
end

local function HidePoolFrom(pool, first)
    local index = first
    local total = table.getn(pool)
    while index <= total do
        if pool[index] == NpcPins.minimapHoverPin then
            Client.HideGameTooltip(pool[index])
            NpcPins.minimapHoverPin = nil
        end
        Client.HideObject(pool[index])
        index = index + 1
    end
    return first - 1
end

function NpcPins:HideAll()
    self.worldVisible = HidePoolFrom(self.worldPool, 1)
    self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
    self:HideNavMark(self.worldNavMark)
    self.worldNavMarkVisible = false
    self:HideNavMark(self.minimapNavMark)
    self.minimapNavMarkVisible = false
    self:HidePatrolRoute(nil)
end

function NpcPins:HideNavMark(mark)
    if mark then
        Client.HideObject(mark)
    end
end

function NpcPins:GetMenuEntries()
    local entries = {}
    local index = 1
    local total = table.getn(CATEGORIES)
    while index <= total do
        local category = CATEGORIES[index]
        local label = UQ.L(category.labelKey)
        if category.key == "trainer" and type(self.playerClassName) == "string" then
            label = label .. " (" .. self.playerClassName .. ")"
        end
        table.insert(entries, {
            key = category.key,
            setting = category.setting,
            label = label,
            checked = Setting(category.setting) and true or false,
            red = category.red,
            green = category.green,
            blue = category.blue,
            icon = category.icon,
            separator = category.separator and true or false,
        })
        index = index + 1
    end
    return entries
end

-- One category's presentation, for a layer that draws the same KIND of point
-- from a different source -- Map/QuestVendorPins.lua puts a quest's vendors on
-- the map with the vendor row's own artwork and colour. Handed out as a copy
-- so the menu's own table cannot be edited from outside, and read through this
-- rather than duplicated over there so the two can never drift into showing
-- two different icons for the same thing. Returns nil for an unknown key.
function NpcPins:GetCategory(key)
    local category = CATEGORY_BY_KEY[key]
    if not category then
        return nil
    end
    return {
        key = category.key,
        labelKey = category.labelKey,
        icon = category.icon,
        red = category.red,
        green = category.green,
        blue = category.blue,
    }
end

function NpcPins:ToggleMenu(anchor)
    local menuAnchor = anchor or self.button
    if not menuAnchor then
        return
    end
    if Client.IsNpcFilterMenuShown() then
        Client.HideNpcFilterMenu()
        return
    end
    Client.ShowNpcFilterMenu(menuAnchor, self:GetMenuEntries(), function(entry)
        if entry and type(entry.setting) == "string" then
            Store(entry.setting, entry.checked and true or false)
            NpcPins.dirty = true
            NpcPins:Refresh()
        end
    end)
end

function NpcPins:Selection()
    local selected = {}
    local count = 0
    local signature = ""
    local index = 1
    local total = table.getn(CATEGORIES)
    while index <= total do
        local category = CATEGORIES[index]
        local enabled = Setting(category.setting) and true or false
        selected[category.key] = enabled
        signature = signature .. (enabled and "1" or "0")
        if enabled then count = count + 1 end
        index = index + 1
    end
    local tracked = self:GetTrackedMobIds()
    local trackedIndex = 1
    local trackedTotal = table.getn(tracked)
    while trackedIndex <= trackedTotal do
        signature = signature .. ":" .. tostring(tracked[trackedIndex])
        trackedIndex = trackedIndex + 1
    end
    if trackedTotal > 0 then
        selected.tracked = true
        count = count + 1
    end
    return selected, count, signature, tracked
end

-- The tracked creature IDs. Single-select means this holds one entry at most
-- from any list this build wrote, but it stays a LIST: a saved file from an
-- earlier build may hold several, and both consumers -- the pin scene here and
-- HUD/MobNavigator.lua's spawn scene -- then draw all of them rather than
-- silently picking one until the player next taps a row.
--
-- Sorted rather than in `pairs` order because both consumers build a cache
-- signature from it, and a hash-ordered list would rebuild both on arbitrary
-- ticks.
function NpcPins:GetTrackedMobIds()
    local tracked = {}
    local config = Config()
    local section = config and config:GetSection("trackedMobs")
    if type(section) == "table" then
        local unitId, enabled
        for unitId, enabled in pairs(section) do
            if type(unitId) == "number" and enabled then
                table.insert(tracked, unitId)
            end
        end
        table.sort(tracked)
    end
    return tracked
end

-- The tracked creature, or nil. There is at most one: see SetMobTracked.
function NpcPins:GetTrackedMobId()
    local tracked = self:GetTrackedMobIds()
    return tracked[1]
end

function NpcPins:IsMobTracked(unitId)
    if type(unitId) ~= "number" then
        return false
    end
    local config = Config()
    local section = config and config:GetSection("trackedMobs")
    return type(section) == "table" and section[unitId] and true or false
end

-- Tracking is SINGLE-SELECT: taking a creature drops whichever was held
-- before, so the stored section never carries more than one entry.
--
-- The reason is the arrow, not the pins. HUD/MobNavigator.lua aims at the
-- nearest spawn of whatever is tracked, so several tracked creatures made the
-- dial swap targets as the player moved -- and the caption naming a different
-- creature every few steps reads as a bug rather than as a feature. One
-- creature, one arrow, one ring.
--
-- The section rather than a plain setting is kept deliberately: it is already
-- the persisted shape, it is what Config sanitizes on load, and a saved file
-- written by an earlier build may legitimately hold several entries. Clearing
-- before setting is therefore also the migration -- the first creature tracked
-- after this change collapses an old multi-entry list to one.
function NpcPins:SetMobTracked(unitId, tracked)
    if type(unitId) ~= "number" then
        return false
    end
    local config = Config()
    if not config then
        return false
    end
    if tracked then
        config:ClearSection("trackedMobs")
        if not config:SetSectionEntry("trackedMobs", unitId, true) then
            return false
        end
    elseif not config:SetSectionEntry("trackedMobs", unitId, nil) then
        return false
    end
    self.dirty = true
    self:Refresh()
    return true
end

-- Zero or one, now that tracking is single-select. Kept as a count rather than
-- collapsed into IsMobTracked because the options page prints it.
function NpcPins:GetTrackedMobCount()
    return table.getn(self:GetTrackedMobIds())
end

-- Merges categories carried by the same entity spawn. Repair vendors, for
-- example, become one point with two tooltip lines instead of two overlapping
-- frames whose winner would depend on draw order.
--
-- Only a new point spends a category's share of the pin budget. A location
-- that merges into a spawn already on the map costs nothing but a tooltip
-- line, so it is always taken.
function NpcPins:BuildTargets(areaId, selected, selectedCount, trackedMobs)
    local database = Database()
    if not database or not database.available then
        return {}
    end
    local source = database:GetAreaServiceLocations(
        areaId, self.playerClassId, self.playerRaceId, selected)
    local budget = MAX_PINS
    if type(selectedCount) == "number" and selectedCount > 0 then
        budget = math.floor(MAX_PINS / selectedCount)
    end
    if budget < MIN_PINS_PER_CATEGORY then budget = MIN_PINS_PER_CATEGORY end
    local targets = {}
    local bySpawn = {}
    local used = {}
    local function AppendLocation(location)
        if location.category == "rares" and location.sourceType == "unit"
            and database:IsRankedUnitSuppressed(location.sourceId, areaId) then
            return
        end
        if selected[location.category] then
            local key = location.sourceType .. ":" .. tostring(location.sourceId)
                .. ":" .. tostring(location.x) .. ":" .. tostring(location.y)
            local target = bySpawn[key]
            local spent = used[location.category] or 0
            if not target and spent < budget and table.getn(targets) < MAX_PINS then
                local category = CATEGORY_BY_KEY[location.category]
                target = {
                    x = location.x,
                    y = location.y,
                    areaId = areaId,
                    name = location.name,
                    sourceType = location.sourceType,
                    sourceId = location.sourceId,
                    categories = {},
                    categorySeen = {},
                    details = {},
                    icon = IconForLocation(location, category),
                    small = category.small and true or false,
                    red = category.red,
                    green = category.green,
                    blue = category.blue,
                }
                bySpawn[key] = target
                used[location.category] = spent + 1
                table.insert(targets, target)
            end
            if target and not target.categorySeen[location.category] then
                target.categorySeen[location.category] = true
                target.details[location.category] = location.detail
                if location.category == "rares" then
                    target.rankLabelKey = RankLabelKey(location)
                end
                table.insert(target.categories, location.category)
            end
        end
    end

    local index = 1
    local total = table.getn(source)
    while index <= total do
        AppendLocation(source[index])
        index = index + 1
    end
    if selected.tracked and type(trackedMobs) == "table" then
        local trackedLocations = database:GetTrackedMobLocations(areaId,
            trackedMobs, MAX_PINS)
        index = 1
        total = table.getn(trackedLocations)
        while index <= total do
            AppendLocation(trackedLocations[index])
            index = index + 1
        end
    end
    if selected.instances then
        local entrances = database:GetInstanceEntrances(areaId)
        if type(entrances) == "table" then
            index = 1
            total = table.getn(entrances)
            while index <= total do
                AppendLocation(entrances[index])
                index = index + 1
            end
        end
    end
    return targets
end

function NpcPins:TooltipLines(target, showRemoveHint)
    local lines = {
        { text = target.name, r = UQ.colors.accent[1], g = UQ.colors.accent[2],
          b = UQ.colors.accent[3] },
    }
    local index = 1
    local total = table.getn(target.categories)
    while index <= total do
        local key = target.categories[index]
        local category = CATEGORY_BY_KEY[key]
        if category then
            -- The Rare/Elite/Boss row covers four classifications, so its
            -- line says which one this creature is instead of repeating the
            -- filter's name. A creature whose rank cannot be read falls back
            -- to the row label rather than showing nothing.
            local labelKey = category.labelKey
            if key == "rares" and target.rankLabelKey then
                labelKey = target.rankLabelKey
            end
            local text = UQ.L(labelKey)
            local detail = target.details and target.details[key]
            if type(detail) == "number" then
                if category.detail == "skill" then
                    text = text .. " " .. UQ.L("NPC_DETAIL_SKILL", tostring(detail))
                elseif category.detail == "level" then
                    text = text .. " " .. UQ.L("NPC_DETAIL_LEVEL", tostring(detail))
                end
            end
            table.insert(lines, {
                text = text,
                r = category.red,
                g = category.green,
                b = category.blue,
            })
        end
        index = index + 1
    end
    if REVIEW_REMOVAL_ENABLED and showRemoveHint and target.rankLabelKey then
        table.insert(lines, {
            text = UQ.L("NPC_RARE_REMOVE_HINT"),
            r = 0.55, g = 0.55, b = 0.55,
        })
    end
    return lines
end

-- Records one reviewed creature-area pair for later promotion into bundled
-- data. The current finder has one representative pin per creature per area,
-- so the temporary exclusion deliberately means "this creature in this zone"
-- rather than pretending the medoid pin identifies only one raw spawn.
function NpcPins:IgnoreReviewedTarget(target, pin)
    if not target or target.sourceType ~= "unit"
        or type(target.sourceId) ~= "number" or type(target.areaId) ~= "number"
        or not target.rankLabelKey then
        return false
    end
    local config = Config()
    if not config then
        return false
    end
    local key = tostring(target.sourceId) .. ":" .. tostring(target.areaId)
    local evidence = tostring(target.x or 0) .. "," .. tostring(target.y or 0)
    if not config:SetSectionEntry("rareApproachIgnores", key, evidence) then
        return false
    end

    Client.HideMapTooltip(pin)
    self:SetHoveredMobPin(nil)
    self.dirty = true
    self:Refresh()

    local alert = UQ:GetModule("RareAlert")
    if alert and type(alert.OnRankedUnitIgnored) == "function" then
        alert:OnRankedUnitIgnored(target.sourceId, target.areaId)
    end
    UQ:Print(UQ.L("NPC_RARE_REMOVED", tostring(target.name)))
    return true
end

function NpcPins:ShowRemoveMenu(pin)
    local target = pin and pin.unrealQuestNpcTarget
    if not target or not target.rankLabelKey then
        return false
    end
    Client.HideMapTooltip(pin)
    return Client.ShowMapPinActionMenu(pin, {
        { text = UQ.L("NPC_RARE_REMOVE_ACTION") },
    }, function()
        NpcPins:IgnoreReviewedTarget(target, pin)
    end)
end

local function ClampUnit(value)
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

local function EaseOutCubic(progress)
    local inverse = 1 - ClampUnit(progress)
    return 1 - inverse * inverse * inverse
end

local function EaseInOutCubic(progress)
    progress = ClampUnit(progress)
    if progress < 0.5 then
        return 4 * progress * progress * progress
    end
    local inverse = -2 * progress + 2
    return 1 - inverse * inverse * inverse / 2
end

local function SetPinScale(pin, scale)
    pin.unrealQuestHoverScale = scale
    local size = pin.unrealQuestBaseSize
    Client.SetWorldMapPinSize(pin, size * scale, size * scale)
end

-- Resizes one pin to its current animated scale and updates the scale it is
-- moving towards. A redraw passes animate=false: it must preserve an animation
-- already in flight, but a pooled pin newly assigned to something else resets
-- immediately rather than inheriting its previous owner's hover size.
function NpcPins:ApplyPinSize(pin, size, animate)
    pin.unrealQuestBaseSize = size
    local isHoveredMob = self.hoveredMobPin == pin
        and pin.unrealQuestNpcTarget
        and pin.unrealQuestNpcTarget.rankLabelKey
    local target = isHoveredMob and MOB_HOVER_SCALE or 1
    local current = pin.unrealQuestHoverScale or 1
    if pin.unrealQuestHoverTarget ~= target then
        if animate then
            pin.unrealQuestHoverFrom = current
            pin.unrealQuestHoverElapsed = 0
        else
            current = target
            pin.unrealQuestHoverFrom = target
            pin.unrealQuestHoverElapsed = 0
        end
        pin.unrealQuestHoverTarget = target
    end
    SetPinScale(pin, current)
    return current ~= target
end

function NpcPins:AnimateMobPinHover(elapsed)
    if type(elapsed) ~= "number" or elapsed < 0 then
        elapsed = 0
    end
    local animating = false
    local index = 1
    while index <= self.worldVisible do
        local pin = self.worldPool[index]
        local current = pin and pin.unrealQuestHoverScale
        local target = pin and pin.unrealQuestHoverTarget
        if type(current) == "number" and type(target) == "number" and current ~= target then
            local from = pin.unrealQuestHoverFrom or current
            local animationElapsed = (pin.unrealQuestHoverElapsed or 0) + elapsed
            local progress = ClampUnit(animationElapsed / MOB_HOVER_DURATION)
            local eased
            if target > from then
                eased = EaseOutCubic(progress)
            else
                eased = EaseInOutCubic(progress)
            end
            pin.unrealQuestHoverElapsed = animationElapsed
            if progress >= 1 then
                SetPinScale(pin, target)
            else
                SetPinScale(pin, from + (target - from) * eased)
                animating = true
            end
        end
        index = index + 1
    end
    self.mobPinAnimating = animating
    if not animating then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("map.npcpinemphasis")
        end
    end
end

local function RunMobPinHoverAnimation(elapsed)
    NpcPins:AnimateMobPinHover(elapsed)
end

-- Growing a pin does not move it: every world-map pin is anchored by its
-- centre (Client.PositionWorldMapPin), so a wider pin thickens around the same
-- point instead of drifting off it.
function NpcPins:SetHoveredMobPin(pin)
    if self.hoveredMobPin == pin then
        return
    end
    self.hoveredMobPin = pin
    local animating = false
    local index = 1
    local total = table.getn(self.worldPool)
    while index <= total do
        local candidate = self.worldPool[index]
        if candidate and candidate.unrealQuestBaseSize and index <= self.worldVisible then
            if self:ApplyPinSize(candidate, candidate.unrealQuestBaseSize, true) then
                animating = true
            end
        end
        index = index + 1
    end
    self.mobPinAnimating = animating
    local driver = UQ:GetModule("Driver")
    if not driver then
        self:AnimateMobPinHover(MOB_HOVER_DURATION)
    elseif animating then
        driver:Schedule("map.npcpinemphasis", 0, RunMobPinHoverAnimation)
    else
        driver:Unschedule("map.npcpinemphasis")
    end
end

-- Leaving a pin must not drop a hover that already belongs to another one:
-- this client can deliver the next pin's OnEnter before this OnLeave, and an
-- unguarded clear would shrink the pin the mouse is actually on. The same
-- guard the quest layer's giver/turn-in hover uses, for the same reason.
function NpcPins:ClearHoveredMobPin(pin)
    if self.hoveredMobPin ~= pin then
        return
    end
    self:SetHoveredMobPin(nil)
end

-- A wandering NPC's route, while the mouse is on its world-map pin.
--
-- 28 of the bundled service NPCs move -- Antonio Perelli walks half of Elwynn,
-- Xan'tish crosses Durotar into Orgrimmar -- and so do 65 of the ranked
-- creature-zone pairs this layer draws, 47 of them further from their recorded
-- spawn than the proximity alert's own range. For both, the pin marks one
-- point on a path, and the path is what the player actually has to walk.
--
-- Hover-only, unlike the quest layer's own routes: these pins are a lookup
-- surface a player sweeps across, and a permanent line under every one of them
-- would be map clutter rather than an answer. Object nodes -- herbs, veins,
-- chests -- are never asked about: only a creature can have a route.
--
-- The drawing itself belongs to Map/WorldMapPins.lua, which owns the stroke
-- pools, the stamp geometry and the route data adapter; this layer only names
-- the creature under the cursor.
function NpcPins:PatrolUnitId(pin)
    local target = pin and pin.unrealQuestNpcTarget
    if type(target) ~= "table" or target.sourceType ~= "unit"
        or type(target.sourceId) ~= "number" then
        return nil
    end
    return target.sourceId
end

function NpcPins:ShowPatrolRoute(pin)
    local pins = UQ:GetModule("WorldMapPins")
    local unitId = self:PatrolUnitId(pin)
    -- Remembered so the pins can be taken off the map without the client ever
    -- delivering an OnLeave -- a category switched off, the layer hidden --
    -- and still leave nothing behind. A pin with no creature (an object node)
    -- clears just as a leave does: the route belongs to the LAST pin hovered,
    -- and that is now this one.
    self.patrolHoverUnitId = unitId
    if pins then
        pins:SetHoverPatrolUnit(unitId)
    end
end

-- `pin` is optional: without one this drops whatever route this layer last
-- asked for, which is what the hide paths need. Either way another layer's
-- route is never cleared -- the ID has to match.
function NpcPins:HidePatrolRoute(pin)
    local pins = UQ:GetModule("WorldMapPins")
    local unitId = self:PatrolUnitId(pin) or self.patrolHoverUnitId
    if type(unitId) ~= "number" then
        return
    end
    if self.patrolHoverUnitId == unitId then
        self.patrolHoverUnitId = nil
    end
    if pins then
        pins:ClearHoverPatrolUnit(unitId)
    end
end

function NpcPins:GetWorldPin(index)
    local pin = self.worldPool[index]
    if pin then
        return pin
    end
    pin = Client.CreateWorldMapPin(index + WORLD_INDEX_OFFSET, 1, 1, 1)
    if pin then
        self.worldPool[index] = pin
        Client.SetWorldMapPinSize(pin, WORLD_PIN_SIZE, WORLD_PIN_SIZE)
        Client.RaiseWorldMapPin(pin, 6)
        local onClick = nil
        if REVIEW_REMOVAL_ENABLED then
            onClick = function(first)
                if Client.ResolveClickButton(first) == "RightButton" then
                    NpcPins:ShowRemoveMenu(pin)
                end
            end
        end
        Client.SetWorldMapPinHandlers(pin,
            function()
                if pin.unrealQuestNpcTarget then
                    Client.ShowMapTooltip(pin,
                        NpcPins:TooltipLines(pin.unrealQuestNpcTarget, true))
                end
                if pin.unrealQuestNpcTarget and pin.unrealQuestNpcTarget.rankLabelKey then
                    NpcPins:SetHoveredMobPin(pin)
                end
                NpcPins:ShowPatrolRoute(pin)
            end,
            function()
                NpcPins:ClearHoveredMobPin(pin)
                NpcPins:HidePatrolRoute(pin)
                Client.HideMapTooltip(pin)
            end,
            onClick,
            REVIEW_REMOVAL_ENABLED)
    end
    return pin
end

function NpcPins:GetMinimapPin(index)
    local pin = self.minimapPool[index]
    if pin then
        return pin
    end
    pin = Client.CreateMinimapPin(index + MINIMAP_INDEX_OFFSET,
        MINIMAP_PIN_SIZE, 1, 1, 1)
    if pin then
        self.minimapPool[index] = pin
        Client.SetWorldMapPinHandlers(pin,
            function()
                NpcPins.minimapHoverPin = pin
                if pin.unrealQuestNpcTarget then
                    Client.ShowGameTooltip(pin,
                        NpcPins:TooltipLines(pin.unrealQuestNpcTarget), "ANCHOR_LEFT")
                end
            end,
            function()
                if NpcPins.minimapHoverPin == pin then
                    NpcPins.minimapHoverPin = nil
                end
                Client.HideGameTooltip(pin)
            end,
            nil)
    end
    return pin
end

-- Called by Map/WorldMapPins.lua's one opacity writer. Applied over the whole
-- pool rather than the visible range: a pooled pin that fell out of the last
-- draw keeps its alpha, and a faded one handed back out later would return
-- faded.
local function ApplyPoolAlpha(pool, alpha)
    local index = 1
    local total = table.getn(pool)
    while index <= total do
        local pin = pool[index]
        if pin then
            Client.SetWorldMapPinAlpha(pin, alpha)
        end
        index = index + 1
    end
end

function NpcPins:SetWorldFocusDim(dimmed)
    dimmed = dimmed and true or false
    if self.worldFocusDimmed == dimmed then
        return
    end
    self.worldFocusDimmed = dimmed
    ApplyPoolAlpha(self.worldPool, dimmed and FOCUS_DIM_ALPHA or FOCUS_FULL_ALPHA)
end

function NpcPins:SetMinimapFocusDim(dimmed)
    dimmed = dimmed and true or false
    if self.minimapFocusDimmed == dimmed then
        return
    end
    self.minimapFocusDimmed = dimmed
    ApplyPoolAlpha(self.minimapPool, dimmed and FOCUS_DIM_ALPHA or FOCUS_FULL_ALPHA)
end

-- The ring frames. Both take no handlers, so they keep the mouse-disabled
-- state their constructors start a pin in: the tracked-mob pin inside the ring
-- owns the hover and the tooltip, and a rim that answered either would name
-- the mark instead of the creature.
function NpcPins:GetWorldNavMark()
    if self.worldNavMark then
        return self.worldNavMark
    end
    local accent = UQ.colors.accent
    local mark = Client.CreateWorldMapPin("TrackedMobNavMark",
        accent[1], accent[2], accent[3])
    if mark then
        Client.SetWorldMapPinTexture(mark, Client.FOLLOWED_QUEST_DOT_BORDER_TEXTURE)
        Client.SetWorldMapPinColor(mark, accent[1], accent[2], accent[3])
        Client.SetWorldMapPinMouseEnabled(mark, false)
        Client.SetWorldMapPinLevelBoost(mark, NAV_MARK_LEVEL_BOOST)
        self.worldNavMark = mark
    end
    return mark
end

function NpcPins:GetMinimapNavMark()
    if self.minimapNavMark then
        return self.minimapNavMark
    end
    local accent = UQ.colors.accent
    local mark = Client.CreateMinimapPin("TrackedMobNavMark",
        MINIMAP_PIN_SIZE + NAV_MARK_PADDING, accent[1], accent[2], accent[3])
    if mark then
        Client.SetMinimapPinTexture(mark, Client.FOLLOWED_QUEST_DOT_BORDER_TEXTURE)
        Client.SetMinimapPinColor(mark, accent[1], accent[2], accent[3])
        Client.SetMinimapPinMouseEnabled(mark, false)
        Client.SetMinimapPinLevelBoost(mark, NAV_MARK_LEVEL_BOOST)
        self.minimapNavMark = mark
    end
    return mark
end

-- The spawn the mob navigator's arrow is aiming at, for the zone `areaId` is
-- drawing, or nil. Read on every draw rather than pushed from the navigator:
-- the mark then cannot outlive the arrow, and neither surface has to know
-- about the other's ordering.
function NpcPins:NavMarkPoint(areaId)
    if type(areaId) ~= "number" then
        return nil
    end
    local navigator = MobNavigator()
    if not navigator then
        return nil
    end
    local targetAreaId, x, y = navigator:GetTarget()
    if targetAreaId ~= areaId or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    return x, y
end

function NpcPins:DrawWorldNavMark(alpha)
    local x, y = self:NavMarkPoint(self.lastAreaId)
    local mark = x and self:GetWorldNavMark()
    if not mark then
        self:HideNavMark(self.worldNavMark)
        self.worldNavMarkVisible = false
        return false
    end
    local size = WORLD_PIN_SIZE + NAV_MARK_PADDING
    Client.SetWorldMapPinSize(mark, size, size)
    Client.SetWorldMapPinAlpha(mark, alpha)
    self.worldNavMarkVisible =
        Client.PositionWorldMapPin(mark, x / 100, y / 100) and true or false
    if not self.worldNavMarkVisible then
        Client.HideObject(mark)
    end
    return self.worldNavMarkVisible
end

function NpcPins:DrawWorldMap()
    local alpha = self.worldFocusDimmed and FOCUS_DIM_ALPHA or FOCUS_FULL_ALPHA
    local visible = 0
    local index = 1
    local total = table.getn(self.targets)
    while index <= total do
        local target = self.targets[index]
        local pin = self:GetWorldPin(visible + 1)
        if pin then
            pin.unrealQuestNpcTarget = target
            Client.SetWorldMapPinAlpha(pin, alpha)
            local size = WORLD_PIN_SIZE
            if target.small then size = NODE_WORLD_PIN_SIZE end
            self:ApplyPinSize(pin, size, false)
            if type(target.icon) == "string" then
                Client.SetWorldMapPinTexture(pin, Client.NPC_SERVICE_ICON_ROOT .. target.icon)
            else
                Client.SetWorldMapPinTexture(pin, Client.MINIMAP_OBJECTIVE_TEXTURE)
                Client.SetWorldMapPinColor(pin, target.red, target.green, target.blue)
            end
            if Client.PositionWorldMapPin(pin, target.x / 100, target.y / 100) then
                visible = visible + 1
            else
                Client.HideObject(pin)
            end
        end
        index = index + 1
    end
    self.worldVisible = HidePoolFrom(self.worldPool, visible + 1)
    self:DrawWorldNavMark(alpha)
end

function NpcPins:DrawMinimap(report, areaId)
    if Client.IsMinimapRotating() then
        self:HideMinimapPins()
        return
    end
    local width, height, zoom = Client.GetMinimapGeometry()
    local database = Database()
    local minimapPins = MinimapPins()
    local yards = database and database:GetZoneYards(areaId)
    local span = minimapPins and minimapPins:GetSpanForZoom(zoom, areaId)
    if type(width) ~= "number" or type(height) ~= "number" or type(span) ~= "number"
        or type(yards) ~= "table" or type(yards[1]) ~= "number"
        or type(yards[2]) ~= "number" then
        self:HideMinimapPins()
        return
    end

    local yardsPerPixel = span / width
    local shortest = width
    if height < shortest then shortest = height end
    -- A half-size node may sit a little closer to the rim before its own
    -- edge would cross it, so each size keeps its own cutoff instead of the
    -- larger one hiding small pins early.
    local limit = shortest / 2 - MINIMAP_PIN_SIZE / 2 - MINIMAP_MARGIN
    if limit < 0 then limit = 0 end
    local nodeLimit = shortest / 2 - NODE_MINIMAP_PIN_SIZE / 2 - MINIMAP_MARGIN
    if nodeLimit < 0 then nodeLimit = 0 end
    -- The rim a clamped tracked pin rests on. Sized for the RING rather than
    -- the pin, because the ring is the larger of the two and is drawn
    -- concentric with it: containing the ring contains both, and nothing
    -- clips a child of the minimap on this client.
    local trackedRim = shortest / 2
        - (MINIMAP_PIN_SIZE + NAV_MARK_PADDING) / 2 - MINIMAP_MARGIN
    if trackedRim < 0 then trackedRim = 0 end
    local visible = 0
    local clamped = 0
    local index = 1
    local total = table.getn(self.minimapTargets)
    while index <= total do
        local target = self.minimapTargets[index]
        local offsetX = ((target.x / 100) - report.playerX) * yards[1] / yardsPerPixel
        local offsetY = -(((target.y / 100) - report.playerY) * yards[2]) / yardsPerPixel
        local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)
        local reach = limit
        if target.small then reach = nodeLimit end
        -- Off-view is the end of it for everything but the tracked creature,
        -- which is pulled to the rim whatever minimapPinsClampEdge says: that
        -- switch is about the incidental markers around the player, and this
        -- is the one pin they asked for by name.
        local onEdge = false
        local draw = distance <= reach
        if not draw and target.categorySeen and target.categorySeen.tracked then
            offsetX, offsetY, onEdge = ClampToRim(offsetX, offsetY, distance,
                trackedRim)
            draw = onEdge
        end
        if draw then
            local pin = self:GetMinimapPin(visible + 1)
            if pin then
                pin.unrealQuestNpcTarget = target
                local alpha = self.minimapFocusDimmed and FOCUS_DIM_ALPHA
                    or FOCUS_FULL_ALPHA
                if onEdge then
                    alpha = alpha * MINIMAP_EDGE_ALPHA
                end
                Client.SetMinimapPinAlpha(pin, alpha)
                local size = MINIMAP_PIN_SIZE
                if target.small then size = NODE_MINIMAP_PIN_SIZE end
                Client.SetMinimapPinSize(pin, size, size)
                if type(target.icon) == "string" then
                    Client.SetMinimapPinTexture(pin, Client.NPC_SERVICE_ICON_ROOT .. target.icon)
                else
                    Client.SetMinimapPinTexture(pin, Client.MINIMAP_OBJECTIVE_TEXTURE)
                    Client.SetMinimapPinColor(pin, target.red, target.green, target.blue)
                end
                if Client.PositionMinimapPin(pin, offsetX, offsetY) then
                    visible = visible + 1
                    if onEdge then clamped = clamped + 1 end
                else
                    Client.HideObject(pin)
                end
            end
        end
        index = index + 1
    end
    self.minimapVisible = HidePoolFrom(self.minimapPool, visible + 1)
    self.minimapClamped = clamped
    self:DrawMinimapNavMark(report, areaId, yards, yardsPerPixel, trackedRim)
end

-- One place that clears both the minimap pins and the ring, because every
-- reason to withhold the pins -- a rotating minimap, an unreadable scale, an
-- interior -- withholds the ring for the same reason. Leaving it behind would
-- put a mark on the minimap at the last position that could be computed.
function NpcPins:HideMinimapPins()
    self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
    self:HideNavMark(self.minimapNavMark)
    self.minimapNavMarkVisible = false
end

-- The ring is placed from the same yards-per-pixel and pulled to the same rim
-- as the pin it frames, so the two cannot separate: an aimed spawn on the rim
-- keeps its ring on the rim with it.
function NpcPins:DrawMinimapNavMark(report, areaId, yards, yardsPerPixel, rim)
    local x, y = self:NavMarkPoint(areaId)
    local mark = x and self:GetMinimapNavMark()
    if not mark then
        self:HideNavMark(self.minimapNavMark)
        self.minimapNavMarkVisible = false
        return false
    end
    local offsetX = ((x / 100) - report.playerX) * yards[1] / yardsPerPixel
    local offsetY = -(((y / 100) - report.playerY) * yards[2]) / yardsPerPixel
    local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)
    local size = MINIMAP_PIN_SIZE + NAV_MARK_PADDING
    local onEdge
    offsetX, offsetY, onEdge = ClampToRim(offsetX, offsetY, distance, rim)
    local alpha = self.minimapFocusDimmed and FOCUS_DIM_ALPHA or FOCUS_FULL_ALPHA
    if onEdge then
        alpha = alpha * MINIMAP_EDGE_ALPHA
    end
    Client.SetMinimapPinSize(mark, size, size)
    Client.SetMinimapPinAlpha(mark, alpha)
    self.minimapNavMarkVisible =
        Client.PositionMinimapPin(mark, offsetX, offsetY) and true or false
    if not self.minimapNavMarkVisible then
        Client.HideObject(mark)
    end
    return self.minimapNavMarkVisible
end

function NpcPins:Refresh()
    local selected, selectedCount, signature, trackedMobs = self:Selection()
    if selectedCount == 0 then
        self:HideAll()
        self.lastSelectionSignature = signature
        return
    end

    local mapContext = MapContext()
    if not mapContext then
        self:HideAll()
        return
    end

    -- Two zones, because the two surfaces answer to different things. The
    -- world map draws whatever zone is open, so it follows the view. The
    -- minimap places every pin by subtracting the player's own position, so it
    -- can only ever draw the zone the player is standing in. They are the same
    -- zone in the common case, and one target set then serves both.
    local viewedAreaId = mapContext:GetViewedZone()
    local playerAreaId, report = mapContext:GetCurrentZoneView()
    if not viewedAreaId and not playerAreaId then
        self:HideAll()
        return
    end

    if self.dirty or self.lastAreaId ~= viewedAreaId
        or self.lastPlayerAreaId ~= playerAreaId
        or self.lastSelectionSignature ~= signature then
        if viewedAreaId then
            self.targets = self:BuildTargets(viewedAreaId, selected, selectedCount,
                trackedMobs)
        else
            self.targets = {}
        end
        if playerAreaId and playerAreaId == viewedAreaId then
            self.minimapTargets = self.targets
        elseif playerAreaId then
            self.minimapTargets = self:BuildTargets(playerAreaId, selected,
                selectedCount, trackedMobs)
        else
            self.minimapTargets = {}
        end
        self.lastAreaId = viewedAreaId
        self.lastPlayerAreaId = playerAreaId
        self.lastSelectionSignature = signature
        self.dirty = false
        self.lastWorldDrawAt = nil
        local config = Config()
        if config then
            config:SetSectionEntry("npcPinDiagnostics", "areaId", viewedAreaId or 0)
            config:SetSectionEntry("npcPinDiagnostics", "playerAreaId", playerAreaId or 0)
            config:SetSectionEntry("npcPinDiagnostics", "selected", selectedCount)
            config:SetSectionEntry("npcPinDiagnostics", "targets", table.getn(self.targets))
        end
    end

    local now = Client.Now()
    if not self.lastWorldDrawAt or type(now) ~= "number"
        or now < self.lastWorldDrawAt
        or now - self.lastWorldDrawAt >= WORLD_REFRESH_INTERVAL then
        self:DrawWorldMap()
        self.lastWorldDrawAt = now
    end
    -- Same rule as the quest layer's own pins: the minimap scale indoors
    -- cannot be established on this client, so service pins are withheld
    -- there rather than drawn at the wrong distance. See
    -- MapContext:IsInterior and docs/MINIMAP-PINS.md.
    local pinConfig = Config()
    if not playerAreaId or not report then
        self:HideMinimapPins()
    elseif (not pinConfig or pinConfig:Get("minimapPinsHideIndoors") ~= false)
        and mapContext:IsInterior(report) then
        self:HideMinimapPins()
    else
        self:DrawMinimap(report, playerAreaId)
    end
end

function NpcPins:GetStatus()
    local _, selectedCount = self:Selection()
    return {
        selected = selectedCount,
        targets = table.getn(self.targets),
        worldVisible = self.worldVisible,
        minimapVisible = self.minimapVisible,
        worldNavMark = self.worldNavMarkVisible,
        minimapNavMark = self.minimapNavMarkVisible,
        minimapClamped = self.minimapClamped,
    }
end

function NpcPins:OnInit()
    self.playerClassId = Client.GetPlayerClassId()
    self.playerRaceId = Client.GetPlayerRaceId()
    self.playerClassName = Client.GetPlayerClass()
    UQ:DeclareCapability("npcServicePins", "unverified",
        "the tracker-header selector and service pins reuse verified addon-owned button, world-map and minimap surfaces; the new composite has not yet been visually confirmed")
end

function NpcPins:OnEnable()
    if not self.playerClassId then self.playerClassId = Client.GetPlayerClassId() end
    if not self.playerRaceId then self.playerRaceId = Client.GetPlayerRaceId() end
    if not self.playerClassName then self.playerClassName = Client.GetPlayerClass() end
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("map.npcpins", REFRESH_INTERVAL, function()
            NpcPins:Refresh()
        end)
    end
    self.dirty = true
    self:Refresh()
end
