--[[
UnrealQuest / Map/NpcPins.lua

A movable HUD button and a compact multi-select menu for nearby service NPCs.
Selected services are drawn as exact points on both the current-zone world map
and the minimap. `Data/Database.lua` is the only layer that reads meta.lua and
trainers.lua; this module only consumes normalized service locations.

The world map and minimap reuse their already-confirmed pooled pin contracts.
Minimap points outside the current view are hidden rather than clamped: service
locations are exact coordinates, and collapsing many vendors or trainers onto
one edge point would invent a location that is not in the database.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local NpcPins = UQ:NewModule("NpcPins")

local BUTTON_NAME = "UnrealQuestNpcFinderButton"
local HANDLE_NAME = "UnrealQuestNpcFinderHandle"
local BUTTON_ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"
local REFRESH_INTERVAL = 0.1
local WORLD_REFRESH_INTERVAL = 0.25
local WORLD_INDEX_OFFSET = 6000
local MINIMAP_INDEX_OFFSET = 10000
local WORLD_PIN_SIZE = 10
local MINIMAP_PIN_SIZE = 7
local MINIMAP_MARGIN = 2
local MAX_PINS = 240

local CATEGORIES = {
    { key = "trainer", setting = "npcCategoryTrainer", label = "Class Trainer",
      red = 0.74, green = 0.36, blue = 1.00 },
    { key = "auctioneer", setting = "npcCategoryAuctioneer", label = "Auctioneer",
      red = 1.00, green = 0.73, blue = 0.10 },
    { key = "banker", setting = "npcCategoryBanker", label = "Banker",
      red = 0.74, green = 0.55, blue = 0.24 },
    { key = "battlemaster", setting = "npcCategoryBattlemaster", label = "Battlemaster",
      red = 0.92, green = 0.20, blue = 0.18 },
    { key = "flight", setting = "npcCategoryFlight", label = "Flight Master",
      red = 0.78, green = 0.78, blue = 0.88 },
    { key = "innkeeper", setting = "npcCategoryInnkeeper", label = "Innkeeper",
      red = 0.20, green = 0.78, blue = 0.92 },
    { key = "mailbox", setting = "npcCategoryMailbox", label = "Mailbox",
      red = 0.95, green = 0.95, blue = 0.95 },
    { key = "meetingstone", setting = "npcCategoryMeetingstone", label = "Meeting Stone",
      red = 0.10, green = 0.72, blue = 1.00 },
    { key = "repair", setting = "npcCategoryRepair", label = "Repair",
      red = 0.62, green = 0.66, blue = 0.72 },
    { key = "spirithealer", setting = "npcCategorySpirithealer", label = "Spirit Healer",
      red = 0.34, green = 0.62, blue = 1.00 },
    { key = "stablemaster", setting = "npcCategoryStablemaster", label = "Stable Master",
      red = 0.67, green = 0.42, blue = 0.20 },
    { key = "vendor", setting = "npcCategoryVendor", label = "Vendor",
      red = 1.00, green = 0.52, blue = 0.12 },
}

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
NpcPins.dragged = false
NpcPins.suppressClickUntil = nil
NpcPins.button = nil
NpcPins.handle = nil
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

function NpcPins:ApplyStoredPosition()
    if not self.button then
        return false
    end
    local point = Setting("npcFinderPoint")
    local relativePoint = Setting("npcFinderRelativePoint")
    local x = Setting("npcFinderX")
    local y = Setting("npcFinderY")
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    return Client.SetFrameAnchor(self.button, point, "UIParent",
        type(relativePoint) == "string" and relativePoint or point, x, y)
end

function NpcPins:CapturePosition()
    if not self.button then
        return false
    end
    local point, _, relativePoint, x, y = Client.GetFrameAnchor(self.button)
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        UQ:Warn("the NPC finder button could not report its position")
        return false
    end
    Store("npcFinderPoint", point)
    Store("npcFinderRelativePoint", type(relativePoint) == "string" and relativePoint or point)
    Store("npcFinderX", x)
    Store("npcFinderY", y)
    return true
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
        })
        index = index + 1
    end
    return entries
end

function NpcPins:ToggleMenu()
    if not self.button then
        return
    end
    if Client.IsNpcFilterMenuShown() then
        Client.HideNpcFilterMenu()
        return
    end
    Client.ShowNpcFilterMenu(self.button, self:GetMenuEntries(), function(entry)
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
function NpcPins:BuildTargets(areaId, selected)
    local database = Database()
    if not database or not database.available then
        return {}
    end
    local source = database:GetAreaServiceLocations(
        areaId, self.playerClassId, self.playerRaceId)
    local targets = {}
    local bySpawn = {}
    local index = 1
    local total = table.getn(source)
    while index <= total do
        local location = source[index]
        if selected[location.category] then
            local key = location.sourceType .. ":" .. tostring(location.sourceId)
                .. ":" .. tostring(location.x) .. ":" .. tostring(location.y)
            local target = bySpawn[key]
            if not target and table.getn(targets) < MAX_PINS then
                local category = CATEGORY_BY_KEY[location.category]
                target = {
                    x = location.x,
                    y = location.y,
                    name = location.name,
                    categories = {},
                    categorySeen = {},
                    red = category.red,
                    green = category.green,
                    blue = category.blue,
                }
                bySpawn[key] = target
                table.insert(targets, target)
            end
            if target and not target.categorySeen[location.category] then
                target.categorySeen[location.category] = true
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
        local category = CATEGORY_BY_KEY[target.categories[index]]
        if category then
            table.insert(lines, {
                text = category.label,
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
        Client.SetWorldMapPinTexture(pin, Client.MINIMAP_OBJECTIVE_TEXTURE)
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
        Client.SetMinimapPinTexture(pin, Client.MINIMAP_OBJECTIVE_TEXTURE)
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
            Client.SetWorldMapPinColor(pin, target.red, target.green, target.blue)
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
    local limit = shortest / 2 - MINIMAP_PIN_SIZE / 2 - MINIMAP_MARGIN
    if limit < 0 then limit = 0 end

    local visible = 0
    local index = 1
    local total = table.getn(self.targets)
    while index <= total do
        local target = self.targets[index]
        local offsetX = ((target.x / 100) - report.playerX) * yards[1] / yardsPerPixel
        local offsetY = -(((target.y / 100) - report.playerY) * yards[2]) / yardsPerPixel
        local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)
        if distance <= limit then
            local pin = self:GetMinimapPin(visible + 1)
            if pin then
                Client.SetMinimapPinColor(pin, target.red, target.green, target.blue)
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
        self.targets = self:BuildTargets(areaId, selected)
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
    self:DrawMinimap(report, areaId)
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

    local button = Client.CreateHudButton(BUTTON_NAME, BUTTON_ICON, "NPC")
    if not button then
        UQ:DeclareCapability("npcServicePins", "missing",
            "the movable NPC finder HUD button could not be created")
        UQ:Warn("the NPC finder HUD button could not be created")
        return
    end
    self.button = button
    local handle = Client.CreateHudButtonHandle(button, HANDLE_NAME)
    if not handle then
        Client.HideObject(button)
        UQ:DeclareCapability("npcServicePins", "missing",
            "the NPC finder root was created but its measured Button drag handle could not be created")
        UQ:Warn("the NPC finder button has no drag handle")
        return
    end
    self.handle = handle
    if not self:ApplyStoredPosition() then
        -- No stored position yet (never dragged): land immediately to the
        -- left of wherever the settings icon actually is, not a fixed
        -- screen offset. Not persisted -- CapturePosition takes over the
        -- moment the player drags this button.
        Client.AnchorHudButtonBesideSettingsIcon(button)
    end

    Client.SetObjectScript(handle, "OnDragStart", function()
        NpcPins.dragged = true
        Client.HideNpcFilterMenu()
        if not Client.StartFrameDrag(button) then
            NpcPins.dragged = false
            UQ:Warn("the NPC finder button refused to move")
        end
    end)
    Client.SetObjectScript(handle, "OnDragStop", function()
        Client.StopFrameDrag(button)
        NpcPins:CapturePosition()
        NpcPins.dragged = false
        local now = Client.Now()
        if type(now) == "number" then
            NpcPins.suppressClickUntil = now + 0.1
        end
    end)
    Client.SetObjectScript(handle, "OnClick", function()
        local now = Client.Now()
        if NpcPins.dragged or (type(now) == "number"
            and type(NpcPins.suppressClickUntil) == "number"
            and now <= NpcPins.suppressClickUntil) then
            NpcPins.suppressClickUntil = nil
            return
        end
        NpcPins.suppressClickUntil = nil
        NpcPins:ToggleMenu()
    end)
    Client.SetObjectScript(handle, "OnEnter", function()
        Client.SetHudButtonHovered(button, true)
        Client.ShowGameTooltip(button, {
            { text = "Nearby NPCs", r = UQ.colors.accent[1], g = UQ.colors.accent[2],
              b = UQ.colors.accent[3] },
            { text = "Click to choose map markers.", r = 0.75, g = 0.75, b = 0.75 },
            { text = "Drag to move this button.", r = 0.55, g = 0.55, b = 0.55 },
        }, "ANCHOR_LEFT")
    end)
    Client.SetObjectScript(handle, "OnLeave", function()
        Client.SetHudButtonHovered(button, false)
        Client.HideGameTooltip(button)
    end)
    Client.ShowObject(button)
    UQ:DeclareCapability("npcServicePins", "unverified",
        "the HUD selector and service pins reuse verified addon-owned button, world-map and minimap surfaces; the new composite has not yet been visually confirmed")
end

function NpcPins:OnEnable()
    if not self.playerClassId then self.playerClassId = Client.GetPlayerClassId() end
    if not self.playerRaceId then self.playerRaceId = Client.GetPlayerRaceId() end
    if not self.playerClassName then self.playerClassName = Client.GetPlayerClass() end
    if self.button then Client.ShowObject(self.button) end
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("map.npcpins", REFRESH_INTERVAL, function()
            NpcPins:Refresh()
        end)
    end
    self.dirty = true
    self:Refresh()
end
