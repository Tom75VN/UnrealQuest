--[[
UnrealQuest / Map/QuestVendorPins.lua

Quest items that are BOUGHT, put on the map where they are sold.

Some quests do not want anything killed or looted: "Give Gerard a Drink" wants
a Refreshing Spring Water, "Kodo Hide Bag" wants Coarse Thread, "Dry Times"
wants a Skin of Sweet Rum. Every one of those is a vendor item, and until this
layer existed the map had nothing at all to say about them -- the objective
cloud Map/WorldMapPins.lua draws comes from Database:GetQuestLocations, which
walks the drop and container relations of an objective item and deliberately
not its vendor relation (see Database:GetQuestVendorTargets for why: a vendor
is not where the objective happens, and folding a shopkeeper into the spawn
cloud would move the quest's single point onto him).

So a vendor is drawn as what it is: one exact point, with the NPC finder's own
vendor artwork, exactly like the service pins that layer already places. This
module is Map/NpcPins.lua's shape end to end -- the same two pooled pin
contracts, the same viewed-zone/player-zone split, the same minimap rules --
and takes the icon and colour from NpcPins:GetCategory("vendor") rather than
repeating them, so the two layers cannot drift into two different vendor
icons. What differs is only where the points come from: the quest log and the
bundled item relations, not the bundled service relations.

WHAT IS DRAWN, AND WHAT IS NOT.

  * A quest ready to turn in is finished shopping; nothing is drawn for it.
  * An objective line that names the item answers whether it is still wanted:
    "Coarse Thread: 2/2", or the client's own finished flag, and the vendors
    for that item come off the map. The counters also reach the tooltip.
  * An item no live objective line names -- the item-use case, where the log
    says "Use the kit on a corpse" and never mentions buying the kit -- falls
    back to the bags: carried means bought, so nothing is drawn. A bag that
    cannot be read is not "not carried", and the pin stays.
  * A vendor the player's faction cannot trade with is filtered out through
    QuestEligibility, the same gate the giver "!" pins use.

Nothing here reads the client except through Compatibility/ClientAPI.lua, and
every surface it uses -- pooled world-map pin, pooled minimap pin, map tooltip
-- is one Map/NpcPins.lua and Map/WorldMapPins.lua already use.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestVendorPins = UQ:NewModule("QuestVendorPins")

local REFRESH_INTERVAL = 0.1
local WORLD_REFRESH_INTERVAL = 0.25
-- Bands of their own, clear of the quest layer's pins (0/2000/3000) and of the
-- NPC finder's (6000/10000). Widget names must never collide: the client keys
-- a frame by name, and a second CreateFrame with a name already in use hands
-- back the first frame.
local WORLD_INDEX_OFFSET = 14000
local MINIMAP_INDEX_OFFSET = 18000
local WORLD_PIN_SIZE = 15
local MINIMAP_PIN_SIZE = 14
local MINIMAP_MARGIN = 2
-- A vendor pin is a place to walk to, and a quest log holds twenty quests at
-- most. Even Coarse Thread, the widest-sold objective item in the bundled
-- data, has at most a handful of sellers in one zone -- this is a safety bound
-- on a pathological zone, not an expected crop.
local MAX_PINS = 60

-- Mirrors the NPC finder's vendor row and is only used when that module is not
-- loaded at all. NpcPins:GetCategory is the source of truth; see Presentation.
local FALLBACK_PRESENTATION = {
    labelKey = "NPC_CATEGORY_VENDOR",
    icon = "vendor",
    red = 1.00, green = 0.52, blue = 0.12,
}

QuestVendorPins.worldPool = {}
QuestVendorPins.minimapPool = {}
QuestVendorPins.targets = {}
-- The minimap can only ever draw the zone the player is standing in, so it
-- parts company with self.targets whenever the world map is showing another.
QuestVendorPins.minimapTargets = {}
QuestVendorPins.dirty = true
QuestVendorPins.lastAreaId = nil
QuestVendorPins.lastPlayerAreaId = nil
QuestVendorPins.lastSignature = nil
QuestVendorPins.relevantBagItemIds = {}
QuestVendorPins.lastWorldDrawAt = nil
QuestVendorPins.worldVisible = 0
QuestVendorPins.minimapVisible = 0
-- Whether the quest layer on each surface is holding a hover focus. Which of
-- these pins that focus keeps bright is decided per pin, at draw time -- see
-- FocusAlpha.
QuestVendorPins.worldFocusDimmed = false
QuestVendorPins.minimapFocusDimmed = false

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

local function QuestState()
    return UQ:GetModule("QuestState")
end

local function ObjectiveMatch()
    return UQ:GetModule("ObjectiveMatch")
end

local function BagItems()
    return UQ:GetModule("BagItems")
end

local function QuestEligibility()
    return UQ:GetModule("QuestEligibility")
end

local function WorldMapPins()
    return UQ:GetModule("WorldMapPins")
end

local function Enabled()
    local config = Config()
    -- Absent config means the addon is still coming up, not that the player
    -- turned this off; the default is on, so it draws.
    return not config or config:Get("questVendorPins") ~= false
end

-- The vendor row's artwork and colour, asked for once per rebuild.
local function Presentation()
    local npcPins = UQ:GetModule("NpcPins")
    local category = npcPins and npcPins.GetCategory and npcPins:GetCategory("vendor")
    if category then
        return category
    end
    return FALLBACK_PRESENTATION
end

local function HidePoolFrom(pool, first)
    local index = first
    local total = table.getn(pool)
    while index <= total do
        if pool[index] == QuestVendorPins.minimapHoverPin then
            Client.HideGameTooltip(pool[index])
            QuestVendorPins.minimapHoverPin = nil
        end
        Client.HideObject(pool[index])
        index = index + 1
    end
    return first - 1
end

function QuestVendorPins:HideAll()
    self.worldVisible = HidePoolFrom(self.worldPool, 1)
    self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
    self:HidePatrolRoute(nil)
end

-- Which database IDs one live quest row may draw for. A resolved row is its
-- own ID; an honestly ambiguous row is the union of its same-title candidates,
-- exactly as the objective tiles treat it (Map/WorldMapPins.lua's
-- GetQuestMapIds, which this defers to so the two cannot disagree about what
-- an ambiguous row is allowed to show).
function QuestVendorPins:GetQuestIds(quest)
    local worldMapPins = WorldMapPins()
    if worldMapPins and worldMapPins.GetQuestMapIds then
        return worldMapPins:GetQuestMapIds(quest)
    end
    local ids = {}
    if quest and type(quest.questId) == "number" then
        table.insert(ids, quest.questId)
    end
    return ids
end

-- Whether this quest still wants that item, plus the counters to show for it.
--
-- Returns needed, have, need. `have`/`need` are nil whenever the live log line
-- carries no counter or does not exist at all -- a missing counter is not a
-- zero, and the tooltip prints nothing rather than inventing "0/1".
function QuestVendorPins:ItemNeeded(quest, target)
    local objectiveMatch = ObjectiveMatch()
    local itemKey = UQ.NameKey(target.itemName)
    local objectives = quest and quest.objectives or {}
    if objectiveMatch and itemKey then
        local index = 1
        local total = table.getn(objectives)
        while index <= total do
            local objective = objectives[index]
            if objective then
                local name, have, need = objectiveMatch:ParseLine(
                    objective.text, objective.objectiveType)
                if name and UQ.NameKey(name) == itemKey then
                    if objective.finished
                        or (type(have) == "number" and type(need) == "number"
                            and have >= need) then
                        return false
                    end
                    return true, have, need
                end
            end
            index = index + 1
        end
    end

    -- No live line names the item: the item-use case. The bags are the only
    -- remaining answer, and an unreadable bag leaves the pin up.
    local bagItems = BagItems()
    local carries = bagItems and bagItems:Carries(target.itemId)
    if carries == true then
        return false
    end
    return true
end

-- One point per vendor spawn, carrying every (quest, item) that sends the
-- player to it. Merging matters here more than it does for services: three
-- quests wanting Coarse Thread are one trip to one shopkeeper, and three
-- overlapping pins would only make the tooltip depend on draw order.
function QuestVendorPins:BuildTargets(areaId)
    local database = Database()
    local questState = QuestState()
    if not database or not database.available or not questState
        or type(areaId) ~= "number" then
        return {}, {}
    end

    local eligibility = QuestEligibility()
    if eligibility then
        -- Once per rebuild, not once per vendor: the player snapshot behind
        -- the faction test costs guarded client calls to build.
        eligibility:RefreshPlayer()
    end

    local presentation = Presentation()
    local targets = {}
    local bySpawn = {}
    local relevantBagItemIds = {}
    local relevantBagItemSeen = {}
    local quests = questState:GetOrderedQuests()
    local questIndex = 1
    local questTotal = table.getn(quests)
    while questIndex <= questTotal do
        local quest = quests[questIndex]
        -- A quest ready to hand in has bought everything it needed.
        if quest and quest.isComplete ~= 1 then
            local red, green, blue = UQ.GetQuestColor(quest)
            local ids = self:GetQuestIds(quest)
            local idIndex = 1
            local idTotal = table.getn(ids)
            while idIndex <= idTotal do
                local rows = database:GetQuestVendorTargets(ids[idIndex])
                local rowIndex = 1
                local rowTotal = table.getn(rows)
                while rowIndex <= rowTotal do
                    local row = rows[rowIndex]
                    if type(row.itemId) == "number" and not relevantBagItemSeen[row.itemId] then
                        relevantBagItemSeen[row.itemId] = true
                        table.insert(relevantBagItemIds, row.itemId)
                    end
                    local needed, have, need = self:ItemNeeded(quest, row)
                    if needed and (not eligibility
                        or eligibility:MatchesGiverFaction({ faction = row.faction })) then
                        local locations = database:GetEntityLocations(
                            "unit", row.unitId, areaId)
                        local locationIndex = 1
                        local locationTotal = table.getn(locations)
                        while locationIndex <= locationTotal do
                            local location = locations[locationIndex]
                            local key = tostring(row.unitId) .. ":"
                                .. tostring(location.x) .. ":" .. tostring(location.y)
                            local target = bySpawn[key]
                            if not target and table.getn(targets) < MAX_PINS then
                                target = {
                                    x = location.x,
                                    y = location.y,
                                    unitId = row.unitId,
                                    name = row.unitName,
                                    icon = presentation.icon,
                                    labelKey = presentation.labelKey,
                                    red = presentation.red,
                                    green = presentation.green,
                                    blue = presentation.blue,
                                    entries = {},
                                    entrySeen = {},
                                }
                                bySpawn[key] = target
                                table.insert(targets, target)
                            end
                            -- A merge into a spawn already on the map costs a
                            -- tooltip line and no pin, so it is always taken.
                            local entryKey = tostring(quest.titleKey) .. ":"
                                .. tostring(row.itemId)
                            if target and not target.entrySeen[entryKey] then
                                target.entrySeen[entryKey] = true
                                table.insert(target.entries, {
                                    quest = quest,
                                    questTitle = UQ.GetQuestDisplayTitle(quest),
                                    itemId = row.itemId,
                                    itemName = row.itemName,
                                    have = have,
                                    need = need,
                                    red = red,
                                    green = green,
                                    blue = blue,
                                })
                            end
                            locationIndex = locationIndex + 1
                        end
                    end
                    rowIndex = rowIndex + 1
                end
                idIndex = idIndex + 1
            end
        end
        questIndex = questIndex + 1
    end
    table.sort(relevantBagItemIds)
    return targets, relevantBagItemIds
end

function QuestVendorPins:TooltipLines(target)
    local objectiveMatch = ObjectiveMatch()
    local lines = {
        { text = target.name or UQ.L("COMMON_UNKNOWN"), r = UQ.colors.accent[1],
          g = UQ.colors.accent[2], b = UQ.colors.accent[3] },
        -- The NPC finder's own vendor label, so the pin reads as the same kind
        -- of point there, followed by the line that says why it is on the map
        -- at all when the player never asked for vendors.
        { text = UQ.L(target.labelKey or "NPC_CATEGORY_VENDOR"),
          r = target.red, g = target.green, b = target.blue },
        { text = UQ.L("QUEST_VENDOR_SELLS"), r = 0.7, g = 0.7, b = 0.7 },
    }
    local index = 1
    local total = table.getn(target.entries)
    while index <= total do
        local entry = target.entries[index]
        table.insert(lines, {
            text = entry.questTitle or UQ.L("COMMON_UNKNOWN"),
            r = entry.red, g = entry.green, b = entry.blue,
        })
        local text = "- " .. (entry.itemName or UQ.L("COMMON_UNKNOWN"))
        local red, green, blue = 1, 1, 1
        -- Counter-only model updates deliberately do not rebuild this static
        -- pin scene. Read the live quest record when the tooltip is opened so
        -- its progress still advances without paying for another map pass.
        local have, need = entry.have, entry.need
        if entry.quest then
            local _, liveHave, liveNeed = self:ItemNeeded(entry.quest, entry)
            have, need = liveHave, liveNeed
        end
        if type(have) == "number" and type(need) == "number" then
            text = text .. " " .. tostring(have) .. "/" .. tostring(need)
            if objectiveMatch then
                red, green, blue = objectiveMatch:ProgressColor(have, need)
            end
        end
        table.insert(lines, { text = text, r = red, g = green, b = blue })
        index = index + 1
    end
    return lines
end

function QuestVendorPins:GetWorldPin(index)
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
                QuestVendorPins.minimapHoverPin = pin
                if pin.unrealQuestVendorTarget then
                    Client.ShowMapTooltip(pin,
                        QuestVendorPins:TooltipLines(pin.unrealQuestVendorTarget))
                end
                QuestVendorPins:ShowPatrolRoute(pin)
            end,
            function()
                QuestVendorPins:HidePatrolRoute(pin)
                Client.HideMapTooltip(pin)
            end,
            nil)
    end
    return pin
end

-- The shopkeeper's route, while the mouse is on its world-map pin. 26 of the
-- vendors selling a bundled quest item wander -- Kira Songshine's basket walks
-- most of Goldshire, Xan'tish leaves Durotar for Orgrimmar -- and the pin can
-- only mark one point of that. Hover-only, and drawn by Map/WorldMapPins.lua,
-- for the reasons given at NpcPins:PatrolUnitId.
local function VendorPatrolUnitId(pin)
    local target = pin and pin.unrealQuestVendorTarget
    if type(target) ~= "table" or type(target.unitId) ~= "number" then
        return nil
    end
    return target.unitId
end

function QuestVendorPins:ShowPatrolRoute(pin)
    local worldMapPins = WorldMapPins()
    local unitId = VendorPatrolUnitId(pin)
    -- Remembered for the hide paths, which have no pin to ask: see
    -- NpcPins:ShowPatrolRoute.
    self.patrolHoverUnitId = unitId
    if worldMapPins and worldMapPins.SetHoverPatrolUnit then
        worldMapPins:SetHoverPatrolUnit(unitId)
    end
end

-- `pin` is optional; another layer's route is never cleared.
function QuestVendorPins:HidePatrolRoute(pin)
    local worldMapPins = WorldMapPins()
    local unitId = VendorPatrolUnitId(pin) or self.patrolHoverUnitId
    if type(unitId) ~= "number" then
        return
    end
    if self.patrolHoverUnitId == unitId then
        self.patrolHoverUnitId = nil
    end
    if worldMapPins and worldMapPins.ClearHoverPatrolUnit then
        worldMapPins:ClearHoverPatrolUnit(unitId)
    end
end

function QuestVendorPins:GetMinimapPin(index)
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
                if pin.unrealQuestVendorTarget then
                    Client.ShowGameTooltip(pin,
                        QuestVendorPins:TooltipLines(pin.unrealQuestVendorTarget), "ANCHOR_LEFT")
                end
            end,
            function()
                if QuestVendorPins.minimapHoverPin == pin then
                    QuestVendorPins.minimapHoverPin = nil
                end
                Client.HideGameTooltip(pin)
            end,
            nil)
    end
    return pin
end

-- The quest hover's fade, reaching the one other layer that draws quest pins.
--
-- Unlike the service and rare pins, a vendor point is not automatically
-- unrelated: it is on the map because some quest wants an item sold there, so
-- it is asked per pin. The question itself is not answered here -- it goes to
-- Map/WorldMapPins.lua's own focus, so the two layers cannot disagree about
-- which quest the cursor is on.
local FOCUS_DIM_ALPHA = 0.25
local FOCUS_FULL_ALPHA = 1

-- `owner` is whichever layer holds the hover -- the world map's own module or
-- the minimap's. Both answer FocusIncludesQuest, and neither is passed as a
-- closure: this runs once per pin per draw pass, and Core/Driver.lua records
-- per-tick closure allocation as a measured stutter hazard on this client.
local function TargetHasFocusedQuest(target, owner)
    local entries = target and target.entries
    if type(entries) ~= "table" then
        return false
    end
    local index = 1
    local total = table.getn(entries)
    while index <= total do
        local entry = entries[index]
        if entry and owner:FocusIncludesQuest(entry.quest) then
            return true
        end
        index = index + 1
    end
    return false
end

local function FocusAlpha(target, dimmed, owner)
    if not dimmed then
        return FOCUS_FULL_ALPHA
    end
    -- A hover is held but the layer that owns it cannot be asked which quest:
    -- fade rather than guess. Nothing here can claim to be the focused quest.
    if not owner or not owner.FocusIncludesQuest then
        return FOCUS_DIM_ALPHA
    end
    if TargetHasFocusedQuest(target, owner) then
        return FOCUS_FULL_ALPHA
    end
    return FOCUS_DIM_ALPHA
end

local function WorldFocusAlpha(target)
    return FocusAlpha(target, QuestVendorPins.worldFocusDimmed, WorldMapPins())
end

local function MinimapFocusAlpha(target)
    return FocusAlpha(target, QuestVendorPins.minimapFocusDimmed, MinimapPins())
end

-- Both setters only record the state and redraw through the normal path: the
-- per-pin answer above needs the target each pin currently carries, and the
-- draw pass is where that is known.
function QuestVendorPins:SetWorldFocusDim(dimmed)
    dimmed = dimmed and true or false
    if self.worldFocusDimmed == dimmed then
        return
    end
    self.worldFocusDimmed = dimmed
    local index = 1
    while index <= self.worldVisible do
        local pin = self.worldPool[index]
        if pin then
            Client.SetWorldMapPinAlpha(pin, WorldFocusAlpha(pin.unrealQuestVendorTarget))
        end
        index = index + 1
    end
end

function QuestVendorPins:SetMinimapFocusDim(dimmed)
    dimmed = dimmed and true or false
    if self.minimapFocusDimmed == dimmed then
        return
    end
    self.minimapFocusDimmed = dimmed
    local index = 1
    while index <= self.minimapVisible do
        local pin = self.minimapPool[index]
        if pin then
            Client.SetMinimapPinAlpha(pin, MinimapFocusAlpha(pin.unrealQuestVendorTarget))
        end
        index = index + 1
    end
end

function QuestVendorPins:DrawWorldMap()
    local visible = 0
    local index = 1
    local total = table.getn(self.targets)
    while index <= total do
        local target = self.targets[index]
        local pin = self:GetWorldPin(visible + 1)
        if pin then
            pin.unrealQuestVendorTarget = target
            Client.SetWorldMapPinAlpha(pin, WorldFocusAlpha(target))
            Client.SetWorldMapPinSize(pin, WORLD_PIN_SIZE, WORLD_PIN_SIZE)
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

-- The NPC finder's minimap rules, unchanged: no pins while the minimap
-- rotates, and a point outside the current view is hidden rather than clamped
-- to the rim -- a vendor's coordinate is exact, and pushing it to the edge
-- would invent a location the data does not have.
function QuestVendorPins:DrawMinimap(report, areaId)
    if Client.IsMinimapRotating() then
        self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
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
    local total = table.getn(self.minimapTargets)
    while index <= total do
        local target = self.minimapTargets[index]
        local offsetX = ((target.x / 100) - report.playerX) * yards[1] / yardsPerPixel
        local offsetY = -(((target.y / 100) - report.playerY) * yards[2]) / yardsPerPixel
        local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY)
        if distance <= limit then
            local pin = self:GetMinimapPin(visible + 1)
            if pin then
                pin.unrealQuestVendorTarget = target
                Client.SetMinimapPinAlpha(pin, MinimapFocusAlpha(target))
                Client.SetMinimapPinSize(pin, MINIMAP_PIN_SIZE, MINIMAP_PIN_SIZE)
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

-- The bag token joins the signature because the item-use fallback in
-- ItemNeeded reads the bags: buying such an item changes what should be drawn
-- without the quest log line ever moving.
function QuestVendorPins:Signature()
    local bagItems = BagItems()
    local config = Config()
    return tostring(self.questStamp) .. "|"
        .. tostring(bagItems and bagItems:GetTokenFor(self.relevantBagItemIds))
        .. "|" .. tostring(UQ.GetLanguage and UQ.GetLanguage())
        .. "|" .. tostring(config and config:Get("translateQuestTitles"))
end

function QuestVendorPins:Refresh()
    if not Enabled() then
        self:HideAll()
        self.dirty = true
        return
    end

    local mapContext = MapContext()
    if not mapContext then
        self:HideAll()
        return
    end

    -- Two zones, the same split Map/NpcPins.lua makes: the world map draws
    -- whichever zone is open, the minimap can only ever draw the one the
    -- player is standing in, and they are the same zone in the common case.
    local viewedAreaId = mapContext:GetViewedZone()
    local playerAreaId, report = mapContext:GetCurrentZoneView()
    if not viewedAreaId and not playerAreaId then
        self:HideAll()
        return
    end

    local signature = self:Signature()
    if self.dirty or self.lastAreaId ~= viewedAreaId
        or self.lastPlayerAreaId ~= playerAreaId
        or self.lastSignature ~= signature then
        local relevantBagItemIds = nil
        if viewedAreaId then
            self.targets, relevantBagItemIds = self:BuildTargets(viewedAreaId)
        else
            self.targets = {}
        end
        if playerAreaId and playerAreaId == viewedAreaId then
            self.minimapTargets = self.targets
        elseif playerAreaId then
            local playerTargets, playerBagItemIds = self:BuildTargets(playerAreaId)
            self.minimapTargets = playerTargets
            if not relevantBagItemIds then
                relevantBagItemIds = playerBagItemIds
            end
        else
            self.minimapTargets = {}
        end
        self.relevantBagItemIds = relevantBagItemIds or {}
        self.lastAreaId = viewedAreaId
        self.lastPlayerAreaId = playerAreaId
        -- BuildTargets established the dependency list, so capture the cache
        -- key again against that list rather than the stale pre-build one.
        self.lastSignature = self:Signature()
        self.dirty = false
        self.lastWorldDrawAt = nil
        local config = Config()
        if config then
            config:SetSectionEntry("questVendorPinDiagnostics", "areaId", viewedAreaId or 0)
            config:SetSectionEntry("questVendorPinDiagnostics", "playerAreaId", playerAreaId or 0)
            config:SetSectionEntry("questVendorPinDiagnostics", "targets",
                table.getn(self.targets))
        end
    end

    local now = Client.Now()
    if not self.lastWorldDrawAt or type(now) ~= "number"
        or now < self.lastWorldDrawAt
        or now - self.lastWorldDrawAt >= WORLD_REFRESH_INTERVAL then
        self:DrawWorldMap()
        self.lastWorldDrawAt = now
    end

    -- Same rule as every other minimap layer here: the minimap scale indoors
    -- cannot be established on this client, so pins are withheld there rather
    -- than drawn at the wrong distance. See docs/MINIMAP-PINS.md.
    local pinConfig = Config()
    if not playerAreaId or not report then
        self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
    elseif (not pinConfig or pinConfig:Get("minimapPinsHideIndoors") ~= false)
        and mapContext:IsInterior(report) then
        self.minimapVisible = HidePoolFrom(self.minimapPool, 1)
    else
        self:DrawMinimap(report, playerAreaId)
    end
end

function QuestVendorPins:GetStatus()
    return {
        enabled = Enabled(),
        targets = table.getn(self.targets),
        worldVisible = self.worldVisible,
        minimapVisible = self.minimapVisible,
    }
end

function QuestVendorPins:OnInit()
    self.questStamp = 0
    UQ:DeclareCapability("questVendorPins", "unverified",
        "vendor points for a quest's bought objective items reuse the world-map and minimap pin "
        .. "surfaces the NPC finder already draws on; the composite has not yet been visually confirmed")
end

function QuestVendorPins:OnEnable()
    local questState = QuestState()
    if questState then
        -- An accelerator, not the mechanism: the poll below rebuilds on its
        -- own whenever the view or the bag token moves. This only makes an
        -- accepted quest or a target-changing objective update show up on the
        -- next tick instead of the next view change. A counter movement that
        -- does not cross completion changes only the tooltip text.
        questState:AddListener(function(event, quest, targetsChanged)
            if event ~= "QUEST_OBJECTIVES_CHANGED" or targetsChanged then
                QuestVendorPins.questStamp = (QuestVendorPins.questStamp or 0) + 1
                QuestVendorPins.dirty = true
            end
        end)
    end
    local driver = UQ:GetModule("Driver")
    if driver then
        driver:Schedule("map.questvendorpins", REFRESH_INTERVAL, function()
            QuestVendorPins:Refresh()
        end)
    end
    self.dirty = true
    self:Refresh()
end
