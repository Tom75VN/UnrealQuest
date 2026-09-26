--[[
UnrealQuest / Map/MinimapAreas.lua

The world map's quest areas, drawn on the minimap around the player.

WHAT IT DRAWS. With the Areas presentation on (mapObjectiveAreas), exactly what
the world map shows: the followed quest's area (every in-progress quest's under
"Show all areas"), plus the area of a quest hovered in the tracker or through
a minimap pin, in the lighter hover blue unless it is the followed quest. A
complete quest draws no area -- its turn-in "?" is the destination.

THE SAME SHAPES. The geometry is Map/AreaContours.lua's, read from its cache
(LayoutPatches/BuildLayout): flat-in-y, linear-in-x texture patches on the
800-cell zone grid, textured from the same profile strip. They are converted to
yards once per rebuild; each refresh only turns yards into pixels around the
player, the same arithmetic MinimapPins:Project uses for the dots.

CLIPPED TO THE CIRCLE. Nothing clips a child of Minimap on this client
(minimap.addon_children_render_unclipped), so a patch left as computed would
be drawn over the rest of the UI. There is no mask to lean on, so every patch
is clipped to the minimap circle here, before it is placed:
  * a patch entirely outside the circle is not drawn;
  * a patch entirely inside is drawn as it is;
  * a patch crossing the rim is cut into horizontal strips at most STRIP_HEIGHT
    pixels tall, and each strip is trimmed to the circle's chord at the strip's
    OUTER edge -- the narrowest chord inside the strip -- so no strip can reach
    past the rim. A patch's texture is constant in y and linear in x, so a
    trimmed strip keeps its exact texels by interpolating u across the cut.
The edge is therefore exact to within one strip (about a pixel), and nothing
is ever drawn outside the circle.

Geometry that is not yet in the cache is built on the shared driver within a
per-tick budget, like the world map's, so a rebuild never computes every area
in one frame.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local MinimapAreas = UQ:NewModule("MinimapAreas")

-- The tallest strip a rim-crossing patch is cut into, in minimap pixels.
local STRIP_HEIGHT = 1.5
-- Kept inside the rim, like the pins' CLAMP_MARGIN, so the soft outer glow
-- never sits on the minimap's border art.
local EDGE_MARGIN = 2
local BUILD_BUDGET = 0.006
-- The lighter blue a hovered area takes unless it is the followed quest's,
-- the same tint as the world map's AREA_HOVER_RGB.
local HOVER_RED, HOVER_GREEN, HOVER_BLUE = 0.45, 0.82, 1

MinimapAreas.entries = {}
MinimapAreas.textures = {}
MinimapAreas.visible = 0
MinimapAreas.buildQueue = {}
MinimapAreas.serial = 0

local function Contours()
    return UQ:GetModule("AreaContours")
end

function MinimapAreas:Enabled(config)
    config = config or UQ:GetModule("Config")
    return config and config:Get("mapObjectiveAreas") and true or false
end

-- Grid patches -> yard rectangles with their u range, plus the bounds of the
-- whole quest, so a quest far from the player is skipped in one test.
local function ToYards(entry, patches, widthYards, heightYards)
    local contours = Contours()
    local grid = contours.GRID
    local scaleX = widthYards / grid
    local scaleY = heightYards / grid
    local records = {}
    local minX, minY, maxX, maxY = nil, nil, nil, nil
    local index = 1
    local total = table.getn(patches)
    while index <= total do
        local patch = patches[index]
        local left = math.max(0, patch[1])
        local top = math.max(0, patch[2])
        local right = math.min(grid, patch[3])
        local bottom = math.min(grid, patch[4])
        if right > left and bottom > top then
            local record = {
                left * scaleX, top * scaleY, right * scaleX, bottom * scaleY,
                contours.ProfileU(patch[5]), contours.ProfileU(patch[6]),
            }
            table.insert(records, record)
            if not minX or record[1] < minX then minX = record[1] end
            if not minY or record[2] < minY then minY = record[2] end
            if not maxX or record[3] > maxX then maxX = record[3] end
            if not maxY or record[4] > maxY then maxY = record[4] end
        end
        index = index + 1
    end
    entry.records = records
    entry.minX, entry.minY, entry.maxX, entry.maxY = minX, minY, maxX, maxY
end

local function RunBuildQueue()
    local self = MinimapAreas
    local contours = Contours()
    local started = Client.Now()
    while contours and table.getn(self.buildQueue) > 0 do
        local entry = table.remove(self.buildQueue, 1)
        if entry.serial == self.serial and not entry.records then
            ToYards(entry, contours:BuildLayout(entry.key, entry.ordered),
                entry.widthYards, entry.heightYards)
            self.lastProjectKey = nil
            local now = Client.Now()
            if not started or not now or now - started >= BUILD_BUDGET then
                break
            end
        end
    end
    if table.getn(self.buildQueue) == 0 then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("map.minimapareas.build")
        end
    end
end

-- Called by MinimapPins:BuildTargets with the scene it just collected. Every
-- in-progress quest is kept (hover can reveal any of them); which ones are
-- drawn is decided per refresh in Project.
function MinimapAreas:Rebuild(quests, areaId, widthYards, heightYards, config)
    self.serial = self.serial + 1
    self.entries = {}
    self.buildQueue = {}
    self.lastProjectKey = nil
    local contours = Contours()
    local worldMap = UQ:GetModule("WorldMapPins")
    if not self:Enabled(config) or not contours or not worldMap
        or type(widthYards) ~= "number" or type(heightYards) ~= "number" then
        return
    end
    local driver = UQ:GetModule("Driver")
    local index = 1
    local total = table.getn(quests or {})
    while index <= total do
        local quest = quests[index]
        if quest and quest.isComplete ~= 1 then
            local locations = worldMap:CollectQuestLocations(quest, areaId, false, config)
            if table.getn(locations) > 0 then
                local patches, key, ordered = contours:LayoutPatches(quest, areaId, locations)
                local entry = { quest = quest, serial = self.serial }
                if patches then
                    ToYards(entry, patches, widthYards, heightYards)
                elseif driver and Client.Now() then
                    entry.key, entry.ordered = key, ordered
                    entry.widthYards, entry.heightYards = widthYards, heightYards
                    table.insert(self.buildQueue, entry)
                else
                    ToYards(entry, contours:BuildLayout(key, ordered), widthYards, heightYards)
                end
                table.insert(self.entries, entry)
            end
        end
        index = index + 1
    end
    if driver and table.getn(self.buildQueue) > 0 then
        driver:Schedule("map.minimapareas.build", 0, RunBuildQueue)
    end
end

function MinimapAreas:GetGroup()
    if not self.group then
        self.group = Client.CreateMinimapAreaGroup()
    end
    return self.group
end

function MinimapAreas:HideFrom(first)
    local index = first
    local total = table.getn(self.textures)
    while index <= total do
        Client.HideObject(self.textures[index])
        index = index + 1
    end
    self.visible = first - 1
end

function MinimapAreas:HideAll()
    self.lastProjectKey = nil
    if self.visible > 0 then
        self:HideFrom(1)
    end
end

function MinimapAreas:Place(index, path, left, top, right, bottom, u1, u2,
    red, green, blue)
    local texture = self.textures[index]
    if not texture then
        texture = Client.CreateMinimapAreaPatch(self:GetGroup())
        if not texture then
            return false
        end
        self.textures[index] = texture
    end
    return Client.PlaceMinimapAreaPatch(texture, path, left, top,
        right - left, top - bottom, u1, u2, 0.25, 0.75, red, green, blue)
end

-- Draws one yard rectangle around the player, clipped to the circle of
-- `radius`. Pixel y runs up, so top > bottom. Returns the next free texture.
function MinimapAreas:DrawRecord(used, record, playerX, playerY, pixelsPerYard,
    radius, path, red, green, blue)
    local left = (record[1] - playerX) * pixelsPerYard
    local right = (record[3] - playerX) * pixelsPerYard
    local top = -(record[2] - playerY) * pixelsPerYard
    local bottom = -(record[4] - playerY) * pixelsPerYard
    local r2 = radius * radius
    -- Nearest point of the rectangle to the centre: outside the circle means
    -- nothing of it is visible.
    local nearX, nearY = 0, 0
    if left > 0 then nearX = left elseif right < 0 then nearX = right end
    if bottom > 0 then nearY = bottom elseif top < 0 then nearY = top end
    if nearX * nearX + nearY * nearY >= r2 then
        return used
    end
    local u1, u2 = record[5], record[6]
    local farX = math.max(math.abs(left), math.abs(right))
    local farY = math.max(math.abs(top), math.abs(bottom))
    if farX * farX + farY * farY <= r2 then
        if self:Place(used, path, left, top, right, bottom, u1, u2, red, green, blue) then
            return used + 1
        end
        return used
    end
    local width = right - left
    local y = top
    while y > bottom do
        local lower = y - STRIP_HEIGHT
        if lower < bottom then lower = bottom end
        -- The chord is narrowest at the strip edge farthest from the centre.
        local outer = math.max(math.abs(y), math.abs(lower))
        if outer < radius then
            local half = math.sqrt(r2 - outer * outer)
            local clipLeft = math.max(left, -half)
            local clipRight = math.min(right, half)
            if clipRight > clipLeft then
                local stripU1 = u1 + (u2 - u1) * (clipLeft - left) / width
                local stripU2 = u1 + (u2 - u1) * (clipRight - left) / width
                if self:Place(used, path, clipLeft, y, clipRight, lower,
                        stripU1, stripU2, red, green, blue) then
                    used = used + 1
                end
            end
        end
        y = lower
    end
    return used
end

-- Called at the end of every MinimapPins:Project. `owner` answers which quest
-- is hovered (MinimapPins:IsQuestAreaHovered). Skipped entirely while nothing
-- it depends on has changed, which is most refreshes of a player standing
-- still.
function MinimapAreas:Project(playerX, playerY, pixelsPerYard, halfSize,
    owner, mainQuest, showAll)
    local radius = halfSize - EDGE_MARGIN
    if radius <= 0 or table.getn(self.entries) == 0 then
        self:HideAll()
        return
    end
    -- Which quests are drawn, and how, is part of the key: a hover or a
    -- follow change redraws even when the player has not moved.
    local drawn = {}
    local keyParts = { self.serial, playerX, playerY, pixelsPerYard, radius }
    local index = 1
    local total = table.getn(self.entries)
    while index <= total do
        local entry = self.entries[index]
        local quest = entry.quest
        local followed = mainQuest and quest.titleKey and mainQuest:IsMain(quest.titleKey) or false
        local hovered = owner and owner:IsQuestAreaHovered(quest) or false
        if entry.records and (followed or showAll or hovered) then
            local tinted = hovered and not followed
            table.insert(drawn, { entry = entry, tinted = tinted })
            table.insert(keyParts, tostring(index) .. (tinted and "h" or "b"))
        end
        index = index + 1
    end
    local key = table.concat(keyParts, "|")
    if key == self.lastProjectKey then
        return
    end
    self.lastProjectKey = key

    local reach = radius / pixelsPerYard
    local used = 1
    index = 1
    total = table.getn(drawn)
    while index <= total do
        local entry = drawn[index].entry
        -- The whole quest outside the square around the circle: skip it.
        if entry.minX and entry.maxX >= playerX - reach and entry.minX <= playerX + reach
            and entry.maxY >= playerY - reach and entry.minY <= playerY + reach then
            local path, red, green, blue = Client.WORLD_MAP_AREA_CONTOUR_TEXTURE, 1, 1, 1
            if drawn[index].tinted then
                path = Client.WORLD_MAP_AREA_CONTOUR_NEUTRAL_TEXTURE
                red, green, blue = HOVER_RED, HOVER_GREEN, HOVER_BLUE
            end
            local records = entry.records
            local recordIndex = 1
            local recordTotal = table.getn(records)
            while recordIndex <= recordTotal do
                used = self:DrawRecord(used, records[recordIndex], playerX, playerY,
                    pixelsPerYard, radius, path, red, green, blue)
                recordIndex = recordIndex + 1
            end
        end
        index = index + 1
    end
    self:HideFrom(used)
end

function MinimapAreas:GetStatus()
    return {
        quests = table.getn(self.entries),
        pending = table.getn(self.buildQueue),
        patches = self.visible,
    }
end
