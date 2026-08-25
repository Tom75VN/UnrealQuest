--[[
UnrealQuest / Map/NpcPins.lua

A compact multi-select menu for nearby service NPCs and world nodes, opened
from the quest tracker's spyglass. Selected categories are drawn as exact
points on both the current-zone world map and the minimap. `Data/Database.lua`
is the only layer that reads meta.lua and trainers.lua; this module only
consumes normalized service locations.

The menu holds two groups divided by a one-pixel rule: the twelve service
categories, then the five world-node categories (chests, herbs, mines, fishing
pools, rare mobs) taken from the same bundled meta relations. Nodes are far
denser than services -- hundreds per zone -- so they are only read out of the
database while checked, and the pin budget is split per category.

The world map and minimap reuse their already-confirmed pooled pin contracts.
Minimap points outside the current view are hidden rather than clamped: service
locations are exact coordinates, and collapsing many vendors or trainers onto
one edge point would invent a location that is not in the database.
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
-- Gathering nodes draw at half size on both maps. A service is one point the
-- player is looking for; herbs and veins come in dense fields, and at the
-- service size those fields cover the terrain they are supposed to sit on.
-- The pools are shared, so the size is applied on every draw rather than once
-- at creation -- a pin that carried a node last frame may carry a vendor next.
local NODE_WORLD_PIN_SIZE = WORLD_PIN_SIZE / 2
local NODE_MINIMAP_PIN_SIZE = MINIMAP_PIN_SIZE / 2
local MINIMAP_MARGIN = 2
local MAX_PINS = 480
-- World nodes come in the hundreds per zone where services come in dozens, so
-- one global ceiling would let the first category alphabetically consume the
-- whole budget and silently erase the rest of the selection. The budget is
-- therefore split evenly across whatever is checked, with a floor so a large
-- selection still shows something of each.
local MIN_PINS_PER_CATEGORY = 60

local CATEGORIES = {
    { key = "trainer", setting = "npcCategoryTrainer", label = "Class Trainer",
      icon = "trainers-icon",
      red = 0.74, green = 0.36, blue = 1.00 },
    { key = "auctioneer", setting = "npcCategoryAuctioneer", label = "Auctioneer",
      icon = "auctioneer",
      red = 1.00, green = 0.73, blue = 0.10 },
    { key = "banker", setting = "npcCategoryBanker", label = "Banker",
      icon = "banker",
      red = 0.74, green = 0.55, blue = 0.24 },
    { key = "battlemaster", setting = "npcCategoryBattlemaster", label = "Battlemaster",
      icon = "battlemaster",
      red = 0.92, green = 0.20, blue = 0.18 },
    { key = "flight", setting = "npcCategoryFlight", label = "Flight Master",
      icon = "flight",
      red = 0.78, green = 0.78, blue = 0.88 },
    { key = "innkeeper", setting = "npcCategoryInnkeeper", label = "Innkeeper",
      icon = "innkeeper",
      red = 0.20, green = 0.78, blue = 0.92 },
    { key = "mailbox", setting = "npcCategoryMailbox", label = "Mailbox",
      icon = "mailbox",
      red = 0.95, green = 0.95, blue = 0.95 },
    { key = "meetingstone", setting = "npcCategoryMeetingstone", label = "Meeting Stone",
      icon = "meetingstone",
      red = 0.10, green = 0.72, blue = 1.00 },
    { key = "repair", setting = "npcCategoryRepair", label = "Repair",
      icon = "repair",
      red = 0.62, green = 0.66, blue = 0.72 },
    { key = "spirithealer", setting = "npcCategorySpirithealer", label = "Spirit Healer",
      icon = "spirithealer",
      red = 0.34, green = 0.62, blue = 1.00 },
    { key = "stablemaster", setting = "npcCategoryStablemaster", label = "Stable Master",
      icon = "stablemaster",
      red = 0.67, green = 0.42, blue = 0.20 },
    { key = "vendor", setting = "npcCategoryVendor", label = "Vendor",
      icon = "vendor",
      red = 1.00, green = 0.52, blue = 0.12 },

    -- World nodes. `separator` draws the one-pixel rule that divides them from
    -- the service rows above; `detail` names what the meta value on this
    -- relation means, for the tooltip.
    { key = "chests", setting = "npcCategoryChests", label = "Chests & Treasures",
      icon = "chests", separator = true,
      red = 1.00, green = 0.82, blue = 0.35 },
    { key = "herbs", setting = "npcCategoryHerbs", label = "Herbs & Flowers",
      icon = "herbs", detail = "skill", small = true,
      red = 0.40, green = 0.85, blue = 0.35 },
    { key = "mines", setting = "npcCategoryMines", label = "Mines & Ores",
      icon = "mines", detail = "skill", small = true,
      red = 0.80, green = 0.62, blue = 0.40 },
    { key = "fish", setting = "npcCategoryFish", label = "Fishing Pools",
      icon = "fish",
      red = 0.35, green = 0.70, blue = 0.95 },
    { key = "rares", setting = "npcCategoryRares", label = "Rare Mobs",
      icon = "rares", detail = "level",
      red = 0.95, green = 0.85, blue = 0.20 },
}

-- A herb or a vein draws its own artwork rather than the category icon, so a
-- Peacebloom pin is recognizable as Peacebloom. `Data/NodeIcons.lua` maps the
-- object ID to a file under media/icons/<category>/; an object it does not
-- name -- Incendicite, Indurium, the Obsidian Chunks -- keeps the category
-- icon. Only objects are looked up: no unit category has per-entity artwork.
local function IconForLocation(location, category)
    if location.sourceType ~= "object" or type(UQ.nodeIcons) ~= "table" then
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

NpcPins.worldPool = {}
NpcPins.minimapPool = {}
NpcPins.targets = {}
NpcPins.dirty = true
NpcPins.lastAreaId = nil
NpcPins.lastWorldDrawAt = nil
NpcPins.worldVisible = 0
NpcPins.minimapVisible = 0
NpcPins.playerClassId = nil
NpcPins.playerRaceId = nil
NpcPins.playerClassName = nil

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

local function Setting(key)
    local config = Config()
    return config and config:Get(key)
end

local function Store(key, value)
    local config = Config()
    return config and config:Set(key, value)
end

local function HidePoolFrom(pool, first)
    local index = first
    local total = table.getn(pool)
    while index <= total do
        Client.HideObject(pool[index])
        index = index + 1
    end
    return first - 1
end

function NpcPins:HideAll()
    self.worldVisible = HidePoolFrom(self.worldPool, 1)
    self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
end

function NpcPins:GetMenuEntries()
    local entries = {}
    local index = 1
    local total = table.getn(CATEGORIES)
    while index <= total do
        local category = CATEGORIES[index]
        local label = category.label
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
    return selected, count, signature
end

-- Merges categories carried by the same entity spawn. Repair vendors, for
-- example, become one point with two tooltip lines instead of two overlapping
-- frames whose winner would depend on draw order.
--
-- Only a new point spends a category's share of the pin budget. A location
-- that merges into a spawn already on the map costs nothing but a tooltip
-- line, so it is always taken.
function NpcPins:BuildTargets(areaId, selected, selectedCount)
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
    local index = 1
    local total = table.getn(source)
    while index <= total do
        local location = source[index]
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
                    name = location.name,
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
                table.insert(target.categories, location.category)
            end
        end
        index = index + 1
    end
    return targets
end

function NpcPins:TooltipLines(target)
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
            local text = category.label
            local detail = target.details and target.details[key]
            if type(detail) == "number" then
                if category.detail == "skill" then
                    text = text .. " (skill " .. tostring(detail) .. ")"
                elseif category.detail == "level" then
                    text = text .. " (level " .. tostring(detail) .. ")"
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
    return lines
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
        Client.SetWorldMapPinHandlers(pin,
            function()
                if pin.unrealQuestNpcTarget then
                    Client.ShowMapTooltip(pin,
                        NpcPins:TooltipLines(pin.unrealQuestNpcTarget))
                end
            end,
            function() Client.HideMapTooltip(pin) end,
            nil)
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
    end
    return pin
end

function NpcPins:DrawWorldMap()
    local visible = 0
    local index = 1
    local total = table.getn(self.targets)
    while index <= total do
        local target = self.targets[index]
        local pin = self:GetWorldPin(visible + 1)
        if pin then
            pin.unrealQuestNpcTarget = target
            local size = WORLD_PIN_SIZE
            if target.small then size = NODE_WORLD_PIN_SIZE end
            Client.SetWorldMapPinSize(pin, size, size)
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
end

function NpcPins:DrawMinimap(report, areaId)
    if Client.IsMinimapRotating() then
        self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
        return
    end
    local width, height, zoom = Client.GetMinimapGeometry()
    local database = Database()
    local minimapPins = MinimapPins()
    local yards = database and database:GetZoneYards(areaId)
    local span = minimapPins and minimapPins:GetSpanForZoom(zoom)
    if type(width) ~= "number" or type(height) ~= "number" or type(span) ~= "number"
        or type(yards) ~= "table" or type(yards[1]) ~= "number"
        or type(yards[2]) ~= "number" then
        self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
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

    local visible = 0
    local index = 1
    local total = table.getn(self.targets)
    while index <= total do
        local target = self.targets[index]
        local offsetX = ((target.x / 100) - report.playerX) * yards[1] / yardsPerPixel
        local offsetY = -(((target.y / 100) - report.playerY) * yards[2]) / yardsPerPixel
        local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)
        local reach = limit
        if target.small then reach = nodeLimit end
        if distance <= reach then
            local pin = self:GetMinimapPin(visible + 1)
            if pin then
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
                else
                    Client.HideObject(pin)
                end
            end
        end
        index = index + 1
    end
    self.minimapVisible = HidePoolFrom(self.minimapPool, visible + 1)
end

function NpcPins:Refresh()
    local selected, selectedCount, signature = self:Selection()
    if selectedCount == 0 then
        self:HideAll()
        self.lastSelectionSignature = signature
        return
    end

    local mapContext = MapContext()
    local areaId, report
    if mapContext then
        areaId, report = mapContext:GetCurrentZoneView()
    end
    if not areaId or not report then
        self:HideAll()
        return
    end

    if self.dirty or self.lastAreaId ~= areaId
        or self.lastSelectionSignature ~= signature then
        self.targets = self:BuildTargets(areaId, selected, selectedCount)
        self.lastAreaId = areaId
        self.lastSelectionSignature = signature
        self.dirty = false
        self.lastWorldDrawAt = nil
        local config = Config()
        if config then
            config:SetSectionEntry("npcPinDiagnostics", "areaId", areaId)
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
    if (not pinConfig or pinConfig:Get("minimapPinsHideIndoors") ~= false)
        and mapContext:IsInterior(report) then
        self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
    else
        self:DrawMinimap(report, areaId)
    end
end

function NpcPins:GetStatus()
    local _, selectedCount = self:Selection()
    return {
        selected = selectedCount,
        targets = table.getn(self.targets),
        worldVisible = self.worldVisible,
        minimapVisible = self.minimapVisible,
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
