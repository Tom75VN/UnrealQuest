--[[
UnrealQuest / Data/QuestTarget.lua

Resolves one quest to one point: the middle of the blue area the world map
draws for it.

This module exists to make a guarantee rather than to add a feature. The
component reduction below -- raw spawn cloud to 2.5% cells, cells joined into
disconnected components, each component represented by the occupied cell
nearest its weighted centroid -- used to live inside Map/WorldMapPins.lua,
where it decided where the tiles went. It moved here unchanged so that the HUD
waypoint and the map tiles can never disagree about where a quest is: they are
now the same computation over the same locations, not two implementations of
"the middle of the area".

That is a deliberate design constraint, not an implementation detail. The
waypoint's whole promise is "walk towards the blue area", and a second,
independently-derived centre would eventually point somewhere the map does not.

Which component wins when a quest has several disconnected clusters is
SelectPrimary's decision, and it is the densest one -- the same one the
(currently retired) numbered map marker sat on. Not the nearest: the choice is
stable as the player moves, so the waypoint does not swap targets underfoot.
Changing that is a change to SelectPrimary alone, and both layers follow.

Nothing here reads the client. It is pure arithmetic over the bundled database,
the live objective model and the carried-item set, so it is exercised in full
by the offline smoke test.
]]

local UQ = UnrealQuest
local QuestTarget = UQ:NewModule("QuestTarget")

-- Kept identical to the values Map/WorldMapPins.lua rendered with. The tile
-- size equals the cell size so tiles sit edge to edge: probe 1.31.0 showed
-- overlapping translucent tiles compounding into visibly darker bands, and
-- 1.32.0 confirmed a non-overlapping grid is uniform.
QuestTarget.CELL_PERCENT = 2.5
QuestTarget.LINK_CELLS = 2

local function Database()
    return UQ:GetModule("Database")
end

local function BagItems()
    return UQ:GetModule("BagItems")
end

local function ObjectiveMatch()
    return UQ:GetModule("ObjectiveMatch")
end

local function CellKey(x, y)
    return tostring(x) .. ":" .. tostring(y)
end

-- Reduces a raw spawn-point cloud to occupied cells, then joins nearby cells
-- into disconnected components. A component's point is the occupied cell
-- nearest its weighted centroid, never an arbitrary empty midpoint: the
-- centroid of a ring of spawns sits in the middle of the ring, where there is
-- nothing to do.
function QuestTarget:BuildComponents(locations)
    local cells = {}
    local locationIndex = 1
    local locationTotal = table.getn(locations)
    while locationIndex <= locationTotal do
        local location = locations[locationIndex]
        local cellX = math.floor(location.x / self.CELL_PERCENT)
        local cellY = math.floor(location.y / self.CELL_PERCENT)
        local key = CellKey(cellX, cellY)
        local cell = cells[key]
        if not cell then
            cell = { cellX = cellX, cellY = cellY, count = 0, sumX = 0, sumY = 0 }
            cells[key] = cell
        end
        cell.count = cell.count + 1
        cell.sumX = cell.sumX + location.x
        cell.sumY = cell.sumY + location.y
        locationIndex = locationIndex + 1
    end

    local components = {}
    local visited = {}
    local seedKey, seed
    for seedKey, seed in pairs(cells) do
        if not visited[seedKey] then
            local component = { cells = {}, count = 0, sumX = 0, sumY = 0 }
            local queue = { seed }
            local queueIndex = 1
            visited[seedKey] = true
            while queueIndex <= table.getn(queue) do
                local cell = queue[queueIndex]
                table.insert(component.cells, cell)
                component.count = component.count + cell.count
                component.sumX = component.sumX + cell.sumX
                component.sumY = component.sumY + cell.sumY

                local offsetX = -self.LINK_CELLS
                while offsetX <= self.LINK_CELLS do
                    local offsetY = -self.LINK_CELLS
                    while offsetY <= self.LINK_CELLS do
                        if offsetX ~= 0 or offsetY ~= 0 then
                            local neighborKey = CellKey(cell.cellX + offsetX, cell.cellY + offsetY)
                            local neighbor = cells[neighborKey]
                            if neighbor and not visited[neighborKey] then
                                visited[neighborKey] = true
                                table.insert(queue, neighbor)
                            end
                        end
                        offsetY = offsetY + 1
                    end
                    offsetX = offsetX + 1
                end
                queueIndex = queueIndex + 1
            end

            local centerX = component.sumX / component.count
            local centerY = component.sumY / component.count
            local nearestDistance = nil
            local cellIndex = 1
            local cellTotal = table.getn(component.cells)
            while cellIndex <= cellTotal do
                local cell = component.cells[cellIndex]
                -- Snap visual tiles to their grid centers. Using the raw spawn
                -- average here would shift adjacent equal-size tiles into one
                -- another and compound their alpha into dark bands.
                cell.x = (cell.cellX + 0.5) * self.CELL_PERCENT
                cell.y = (cell.cellY + 0.5) * self.CELL_PERCENT
                local deltaX = cell.x - centerX
                local deltaY = cell.y - centerY
                local distance = deltaX * deltaX + deltaY * deltaY
                if not nearestDistance or distance < nearestDistance then
                    nearestDistance = distance
                    component.x = cell.x
                    component.y = cell.y
                end
                cellIndex = cellIndex + 1
            end
            table.insert(components, component)
        end
    end
    return components
end

-- One quest may have multiple disconnected spawn clusters. All clusters get
-- area coverage on the map, but only the densest cluster owns the quest's
-- single point. Coordinate tie-breakers make the choice stable despite hash
-- iteration order -- which matters more here than it did for a map marker,
-- because an unstable choice would make the HUD waypoint flip between clusters
-- on successive refreshes.
function QuestTarget:SelectPrimary(components)
    local best = nil
    local index = 1
    local total = table.getn(components)
    while index <= total do
        local component = components[index]
        if not best or component.count > best.count
            or (component.count == best.count and component.x < best.x)
            or (component.count == best.count and component.x == best.x
                and component.y < best.y) then
            best = component
        end
        index = index + 1
    end
    return best
end

-- Removes a source's locations only when the live quest log proves that every
-- objective that source can satisfy for this quest is finished. A quest whose
-- three steps sit in three places must lose a place as each step is done --
-- otherwise the map keeps pointing at a container that has already been
-- emptied, and so does the waypoint that shares this list.
--
-- Creatures go through ObjectiveMatch, which owns the two evidence paths for
-- them: exact creature names parsed from kill lines, and bundled links from
-- item objectives to the creatures that drop them.
--
-- Objects are matched by ID against the quest's own object links, because a
-- container's log line names its CONTENTS rather than the container: "Burning
-- Key: 0/1" is what the client says about the Stone of West Binding. Matching
-- the object's own name against the line would only ever answer for the
-- gobject objectives that happen to be named after themselves, which is why
-- the link table resolves the item indirection first.
--
-- An unmatched source stays visible rather than being guessed away, so a
-- source the bundled data ties to no line at all keeps its dots. Area triggers
-- stay conservative for want of a live line that names them.
local function FilterFinishedObjectives(database, quest, locations)
    local objectiveMatch = ObjectiveMatch()
    local objectiveOwner = quest and (quest.objectiveOwner or quest)
    if not objectiveMatch or not objectiveOwner
        or table.getn(objectiveOwner.objectives or {}) == 0 then
        return locations
    end

    -- One memo per source type: a unit ID and an object ID are both plain
    -- numbers and would otherwise share a slot.
    local unitFinished = {}
    local objectFinished = {}
    -- Both resolved on the first object asked about, so a quest with no object
    -- source pays for neither.
    local objectLinks = nil
    local parsedObjectives = nil

    local function UnitFinished(unitId)
        local finished = unitFinished[unitId]
        if finished ~= nil then
            return finished
        end
        finished = false
        local unitKey = UQ.NameKey(database:GetUnitName(unitId))
        local matches = unitKey and objectiveMatch:FindForUnit(unitKey)
        if matches then
            local matched = false
            local unfinished = false
            local matchIndex = 1
            local matchTotal = table.getn(matches)
            while matchIndex <= matchTotal do
                local objective = matches[matchIndex]
                if objective.quest == objectiveOwner then
                    matched = true
                    if not objective.finished then
                        unfinished = true
                    end
                end
                matchIndex = matchIndex + 1
            end
            finished = matched and not unfinished
        end
        unitFinished[unitId] = finished
        return finished
    end

    local function ObjectFinished(objectId)
        local finished = objectFinished[objectId]
        if finished ~= nil then
            return finished
        end
        if objectLinks == nil then
            objectLinks = database:GetQuestObjectiveObjectLinks(quest.questId)
            parsedObjectives = objectiveMatch:ParseQuestObjectives(objectiveOwner)
        end
        finished = false
        local objectiveKeys = objectLinks[objectId]
        if objectiveKeys then
            local matched, unfinished = objectiveMatch:CountObjectiveKeyMatches(
                parsedObjectives, objectiveKeys)
            finished = matched > 0 and unfinished == 0
        end
        objectFinished[objectId] = finished
        return finished
    end

    local function SourceFinished(location)
        if not location or type(location.sourceId) ~= "number" then
            return false
        end
        if location.sourceType == "unit" then
            return UnitFinished(location.sourceId)
        elseif location.sourceType == "object" then
            return ObjectFinished(location.sourceId)
        end
        return false
    end

    local hidesAny = false
    local index = 1
    local total = table.getn(locations)
    while index <= total do
        if SourceFinished(locations[index]) then
            hidesAny = true
        end
        index = index + 1
    end

    if not hidesAny then
        return locations
    end

    local filtered = {}
    index = 1
    while index <= total do
        local location = locations[index]
        if not SourceFinished(location) then
            table.insert(filtered, location)
        end
        index = index + 1
    end
    return filtered
end

-- Both halves of an item-use step, appended according to what the bags say.
-- Database:GetQuestLocations deliberately leaves the whole step out because it
-- is conditional, and which half belongs on the map is a question about live
-- player state that the bundled data cannot answer:
--
--   * carrying the item -- draw where it is USED. Drawing it earlier points at
--     a place the player cannot act on yet (Marla's Last Wish).
--   * not carrying it -- draw where it is FOUND, and only then. These are
--     ordinary creatures with ordinary spawn clouds, and leaving them on the
--     map after the item is in the bag is what buried Frostmaw's single summon
--     coordinate under a hundred Mountain Lion dots.
--   * bags unreadable -- draw where it is found. Unknown is not "not carried",
--     but of the two halves that is the one that cannot strand the player: the
--     acquisition step is the earlier one, and a quest whose bait source is
--     missing from the map has no other way to be started.
--
-- The bag is overruled in one direction only. An obj.IR item is USUALLY pure
-- means, but a handful of quests both count an item and have one of it used
-- somewhere, and for those the quest log says so outright: an unfinished
-- objective line naming the item is the client stating the player still owes
-- some. Carrying one of five is still carrying, so the bag alone would hide
-- the very creatures the remaining four come from. While such a line is
-- unfinished the sources stay and the use target waits, whatever the bags say.
--
-- Marla's Last Wish is the case that shows both halves: its log line reads
-- "Samuel's Remains: 0/1" while the player hunts Samuel Fipps, and the client
-- flips it to finished the moment the remains are looted -- at which point the
-- grave, and only the grave, is what is left to do.
--
-- Returns the count placed and the count withheld because the bags could not
-- be read at all.
function QuestTarget:AppendItemUseLocations(database, quest, areaId, locations)
    local bagItems = BagItems()
    local targets = database:GetQuestItemUseTargets(quest.questId)
    local placed = 0
    local unknown = 0

    -- Item names the live log still wants more of, as name keys. Built once
    -- per call and only when there is an item-use step to decide.
    local owedNames = nil
    local function StillOwed(itemId)
        if owedNames == nil then
            owedNames = {}
            local objectiveMatch = ObjectiveMatch()
            local owner = quest and (quest.objectiveOwner or quest)
            local objectives = objectiveMatch and owner and owner.objectives
            local index = 1
            local total = objectives and table.getn(objectives) or 0
            while index <= total do
                local objective = objectives[index]
                if objective and not objective.finished then
                    local name, _, _, kind = objectiveMatch:ParseLine(
                        objective.text, objective.objectiveType)
                    -- A kill line names a creature, never the item itself.
                    if name and kind ~= "unit" then
                        local key = UQ.NameKey(name)
                        if key then
                            owedNames[key] = true
                        end
                    end
                end
                index = index + 1
            end
        end
        local itemKey = UQ.NameKey(database:GetItemName(itemId))
        return itemKey ~= nil and owedNames[itemKey] == true
    end

    -- Asked once per item rather than once per target: one item may be used on
    -- several things, and its own sources must not be appended once for each.
    local carriedByItem = {}
    local function Carries(itemId)
        local carries = carriedByItem[itemId]
        if carries == nil then
            carries = bagItems and bagItems:Carries(itemId)
            if carries == nil then
                carries = "unknown"
            end
            carriedByItem[itemId] = carries
        end
        if carries == "unknown" then
            return nil
        end
        return carries
    end

    local function AppendFound(found)
        local foundIndex = 1
        local foundTotal = table.getn(found)
        while foundIndex <= foundTotal do
            table.insert(locations, found[foundIndex])
            placed = placed + 1
            foundIndex = foundIndex + 1
        end
    end

    local index = 1
    local total = table.getn(targets)
    local sourcesDone = {}
    while index <= total do
        local target = targets[index]
        local carries = Carries(target.itemId) and not StillOwed(target.itemId)
        if carries then
            AppendFound(database:GetEntityLocations(
                target.sourceType, target.sourceId, areaId))
        else
            if carries == nil then
                unknown = unknown + 1
            end
            -- Where to get it, once per item however many targets it has.
            if not sourcesDone[target.itemId] then
                sourcesDone[target.itemId] = true
                AppendFound(database:GetQuestItemUseSourceLocations(
                    quest.questId, target.itemId, areaId))
            end
        end
        index = index + 1
    end
    return placed, unknown
end

-- Every location that contributes to a quest's drawn area, in one call, so the
-- map layer and the waypoint cannot drift apart by collecting different sets.
-- Returns the list plus the number of item-use targets withheld for want of a
-- readable bag.
function QuestTarget:CollectLocations(quest, areaId, complete)
    local database = Database()
    if not database or not database.available or type(quest) ~= "table"
        or type(quest.questId) ~= "number" then
        return {}, 0
    end
    local locations = database:GetQuestLocations(quest.questId, complete, areaId)
    local unknown = 0
    if not complete then
        locations = FilterFinishedObjectives(database, quest, locations)
        -- GetQuestLocations returns a cached, shared list, and appending the
        -- item-use targets to it would write the carried-item state of one
        -- moment into an answer that is supposed to be static. Copy first --
        -- but only when this quest actually has an item-use step, so the
        -- ordinary quest keeps returning the cached list untouched.
        if table.getn(database:GetQuestItemUseTargets(quest.questId)) > 0 then
            local copy = {}
            local index = 1
            local total = table.getn(locations)
            while index <= total do
                table.insert(copy, locations[index])
                index = index + 1
            end
            locations = copy
        end
        local _, withheld = self:AppendItemUseLocations(
            database, quest, areaId, locations)
        unknown = withheld
    end
    return locations, unknown
end

-- The quest's point on the current map, in database percentages (0-100), or
-- nil plus a reason. `complete` selects the turn-in relation over the
-- objective relation, exactly as the map's green tiles do, so a quest ready to
-- hand in points at its ender rather than at creatures already killed.
function QuestTarget:Resolve(quest, areaId)
    if type(quest) ~= "table" or type(quest.questId) ~= "number" then
        return nil, "unresolvedQuest"
    end
    if type(areaId) ~= "number" then
        return nil, "noArea"
    end

    local complete = quest.isComplete == 1
    local locations, itemUseUnknown = self:CollectLocations(quest, areaId, complete)
    if table.getn(locations) == 0 then
        -- Two very different situations share this exit and the caller needs
        -- to be able to tell them apart: the quest has no recorded location in
        -- this area at all, or it has one but every candidate was an item-use
        -- target the bags could not confirm.
        if itemUseUnknown > 0 then
            return nil, "itemUseUnknown"
        end
        return nil, "noLocationsInArea"
    end

    local components = self:BuildComponents(locations)
    local primary = self:SelectPrimary(components)
    if not primary then
        return nil, "noComponent"
    end

    return {
        x = primary.x,
        y = primary.y,
        areaId = areaId,
        complete = complete,
        componentCount = table.getn(components),
        locationCount = table.getn(locations),
        spawnCount = primary.count,
        itemUseUnknown = itemUseUnknown,
    }
end

-- Converts a displacement in database percentages into real yards, using the
-- bundled per-area width/height. This is what makes the waypoint's bearing and
-- distance true rather than approximate: percentages are not isotropic -- a
-- Vanilla zone map is about 1.5 times wider than it is tall in yards -- so a
-- bearing taken from raw percentage deltas is skewed, and a distance taken
-- from them has no unit at all.
--
-- Returns eastYards, southYards, or nil when the area has no recorded
-- dimensions. The caller must handle nil rather than substituting a constant:
-- the bundled minimap table does not cover every area ID.
function QuestTarget:ToYards(areaId, deltaXPercent, deltaYPercent)
    local database = Database()
    if not database or not database.available then
        return nil
    end
    local yards = database:GetZoneYards(areaId)
    if type(yards) ~= "table" then
        return nil
    end
    local width = yards[1]
    local height = yards[2]
    if type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return nil
    end
    return deltaXPercent / 100 * width, deltaYPercent / 100 * height
end

function QuestTarget:OnInit()
    local database = Database()
    local hasYards = false
    if database and database.available then
        -- Elwynn Forest is the reference area the map layer was validated in;
        -- if its dimensions are present the table survived the reduction.
        hasYards = type(database:GetZoneYards(12)) == "table"
    end
    if hasYards then
        UQ:DeclareCapability("zoneDimensions", "detected",
            "the bundled minimap table maps area IDs to { widthYards, heightYards }, so waypoint "
            .. "bearings and distances are computed in real yards rather than in map percentages. "
            .. "This is bundled world data, never evidence about a client API")
    else
        UQ:DeclareCapability("zoneDimensions", "missing",
            "the bundled minimap table has no dimensions for the reference area; waypoint distance "
            .. "is unavailable and the bearing falls back to raw map percentages, which are skewed "
            .. "by the map's yard aspect ratio")
    end
end
