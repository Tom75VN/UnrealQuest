--[[
UnrealQuest / Map/AreaContours.lua

Builds one rounded, per-cell antialiased contour group per quest from its raw
objective locations. WorldMapPins keeps separate invisible cell hit targets.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local AreaContours = UQ:NewModule("AreaContours")

local GRID = 800
local MAP_SIZE = 100
local Y_SCALE = 2 / 3
local LINK_DISTANCE = 3.6
local HULL_PADDING = 0.85
local CORNER_CUT = 0.45
-- The profile strip: a 256x4 gradient whose texel centres run evenly from
-- signed distance PROFILE_D_MIN (outer edge of the glow, transparent) to
-- PROFILE_D_MAX (end of the inner shadow, flat fill), each already
-- box-filtered over one cell. These must match
-- tools/make_area_contour_textures.py.
local PROFILE_SIZE = 256
local PROFILE_D_MIN = -1.22
local PROFILE_D_MAX = 0.94

AreaContours.PROFILE = {
    size = PROFILE_SIZE, dMin = PROFILE_D_MIN, dMax = PROFILE_D_MAX,
}
-- GetTime does not advance inside one frame on this client, so elapsed-time
-- budgets cannot split this work. Advance an exact number of 800-cell grid
-- rows per driver tick instead; the finished geometry is byte-for-byte the
-- same as the synchronous path.
local BUILD_ROWS_PER_TICK = 8
local PATCH_CACHE_LIMIT = 64
AreaContours.patchCache = {}
AreaContours.patchCacheCount = 0
AreaContours.layoutBuilds = {}
AreaContours.buildQueue = {}
AreaContours.groups = {}
AreaContours.groupPool = {}
AreaContours.visibleCount = 0
AreaContours.nextGroup = 1
AreaContours.enabled = false

local function SpanOrder(a, b)
    return a[1] < b[1]
end

local function PointOrder(a, b)
    if a[1] == b[1] then return a[2] < b[2] end
    return a[1] < b[1]
end

local function GroupOrder(a, b)
    local aTotal = table.getn(a)
    local bTotal = table.getn(b)
    if aTotal ~= bTotal then return aTotal > bTotal end
    if a[1][1] == b[1][1] then return a[1][2] < b[1][2] end
    return a[1][1] < b[1][1]
end

local function Clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function MergeRows(rows, minimum, maximum)
    local y = minimum
    while y and y <= maximum do
        local spans = rows[y]
        if spans then
            table.sort(spans, SpanOrder)
            local merged = {}
            local index = 1
            local total = table.getn(spans)
            while index <= total do
                local span = spans[index]
                local previous = merged[table.getn(merged)]
                if previous and span[1] <= previous[2] then
                    if span[2] > previous[2] then
                        previous[2] = span[2]
                    end
                else
                    table.insert(merged, { span[1], span[2] })
                end
                index = index + 1
            end
            rows[y] = merged
        end
        y = y + 1
    end
end

local function UniquePoints(locations)
    local points = {}
    local seen = {}
    local index = 1
    local total = table.getn(locations or {})
    while index <= total do
        local location = locations[index]
        local x = location and location.x
        local y = location and location.y
        if type(x) == "number" and type(y) == "number"
            and x >= 0 and x <= MAP_SIZE and y >= 0 and y <= MAP_SIZE then
            local key = tostring(x) .. ":" .. tostring(y)
            if not seen[key] then
                seen[key] = true
                table.insert(points, { x, y })
            end
        end
        index = index + 1
    end
    table.sort(points, PointOrder)
    return points
end

local function PointBucket(point)
    return math.floor(point[1] / LINK_DISTANCE),
        math.floor(point[2] * Y_SCALE / LINK_DISTANCE)
end

local function PointDistance(a, b)
    local dx = a[1] - b[1]
    local dy = (a[2] - b[2]) * Y_SCALE
    return math.sqrt(dx * dx + dy * dy)
end

local function BuildClusters(points)
    local buckets = {}
    local index = 1
    local total = table.getn(points)
    while index <= total do
        local x, y = PointBucket(points[index])
        local key = tostring(x) .. ":" .. tostring(y)
        buckets[key] = buckets[key] or {}
        table.insert(buckets[key], index)
        index = index + 1
    end
    local clusters = {}
    local visited = {}
    index = 1
    while index <= total do
        if not visited[index] then
            visited[index] = true
            local queue = { index }
            local queueIndex = 1
            local group = {}
            while queueIndex <= table.getn(queue) do
                local current = points[queue[queueIndex]]
                local bucketX, bucketY = PointBucket(current)
                table.insert(group, current)
                local x = bucketX - 1
                while x <= bucketX + 1 do
                    local y = bucketY - 1
                    while y <= bucketY + 1 do
                        local candidates = buckets[tostring(x) .. ":" .. tostring(y)] or {}
                        local candidateIndex = 1
                        local candidateTotal = table.getn(candidates)
                        while candidateIndex <= candidateTotal do
                            local candidate = candidates[candidateIndex]
                            if not visited[candidate]
                                and PointDistance(current, points[candidate]) <= LINK_DISTANCE then
                                visited[candidate] = true
                                table.insert(queue, candidate)
                            end
                            candidateIndex = candidateIndex + 1
                        end
                        y = y + 1
                    end
                    x = x + 1
                end
                queueIndex = queueIndex + 1
            end
            table.sort(group, PointOrder)
            table.insert(clusters, group)
        end
        index = index + 1
    end
    table.sort(clusters, GroupOrder)
    return clusters
end

local function Cross(origin, a, b)
    return (a[1] - origin[1]) * (b[2] - origin[2])
        - (a[2] - origin[2]) * (b[1] - origin[1])
end

local function ConvexHull(points)
    table.sort(points, PointOrder)
    local lower = {}
    local index = 1
    local total = table.getn(points)
    while index <= total do
        local point = points[index]
        while table.getn(lower) > 1
            and Cross(lower[table.getn(lower) - 1], lower[table.getn(lower)], point) <= 0 do
            table.remove(lower)
        end
        table.insert(lower, point)
        index = index + 1
    end
    local upper = {}
    index = total
    while index >= 1 do
        local point = points[index]
        while table.getn(upper) > 1
            and Cross(upper[table.getn(upper) - 1], upper[table.getn(upper)], point) <= 0 do
            table.remove(upper)
        end
        table.insert(upper, point)
        index = index - 1
    end
    local hull = {}
    index = 1
    while index < table.getn(lower) do
        table.insert(hull, lower[index])
        index = index + 1
    end
    index = 1
    while index < table.getn(upper) do
        table.insert(hull, upper[index])
        index = index + 1
    end
    return hull
end

local function RoundedHull(points)
    local polygon = ConvexHull(points)
    local pass = 1
    while pass <= 2 do
        local rounded = {}
        local index = 1
        local total = table.getn(polygon)
        while index <= total do
            local a = polygon[index]
            local b = polygon[index < total and index + 1 or 1]
            local dx = b[1] - a[1]
            local dy = (b[2] - a[2]) * Y_SCALE
            local length = math.sqrt(dx * dx + dy * dy)
            local amount = math.min(0.25, CORNER_CUT / math.max(length, 0.0001))
            table.insert(rounded, {
                a[1] + (b[1] - a[1]) * amount,
                a[2] + (b[2] - a[2]) * amount,
            })
            table.insert(rounded, {
                b[1] + (a[1] - b[1]) * amount,
                b[2] + (a[2] - b[2]) * amount,
            })
            index = index + 1
        end
        polygon = rounded
        pass = pass + 1
    end
    return polygon
end

local function ExpandedHull(group, padding)
    local expanded = {}
    local pointIndex = 1
    local pointTotal = table.getn(group)
    while pointIndex <= pointTotal do
        local point = group[pointIndex]
        local offsetIndex = 1
        while offsetIndex <= 8 do
            local angle = (offsetIndex - 1) * math.pi / 4
            local offsetX = math.cos(angle) * padding
            local offsetY = math.sin(angle) * padding / Y_SCALE
            table.insert(expanded, {
                Clamp(point[1] + offsetX, 0, MAP_SIZE),
                Clamp(point[2] + offsetY, 0, MAP_SIZE),
            })
            offsetIndex = offsetIndex + 1
        end
        pointIndex = pointIndex + 1
    end
    return RoundedHull(expanded)
end

local function ScanHull(polygon, rows, minimum, maximum)
    local minY = MAP_SIZE
    local maxY = 0
    local index = 1
    local total = table.getn(polygon)
    while index <= total do
        minY = math.min(minY, polygon[index][2])
        maxY = math.max(maxY, polygon[index][2])
        index = index + 1
    end
    local firstRow = math.max(0, math.floor(minY * GRID / MAP_SIZE))
    local lastRow = math.min(GRID - 1, math.ceil(maxY * GRID / MAP_SIZE) - 1)
    local row = firstRow
    while row <= lastRow do
        local scanY = (row + 0.5) * MAP_SIZE / GRID
        local hits = {}
        index = 1
        local previous = total
        while index <= total do
            local a = polygon[previous]
            local b = polygon[index]
            if (a[2] > scanY) ~= (b[2] > scanY) then
                table.insert(hits, a[1] + (scanY - a[2])
                    * (b[1] - a[1]) / (b[2] - a[2]))
            end
            previous = index
            index = index + 1
        end
        table.sort(hits)
        index = 1
        while index < table.getn(hits) do
            local left = math.max(0, math.floor(hits[index] * GRID / MAP_SIZE))
            local right = math.min(GRID, math.ceil(hits[index + 1] * GRID / MAP_SIZE))
            if right > left then
                rows[row] = rows[row] or {}
                table.insert(rows[row], { left, right })
                if not minimum or row < minimum then minimum = row end
                if not maximum or row > maximum then maximum = row end
            end
            index = index + 2
        end
        row = row + 1
    end
    return minimum, maximum
end

function AreaContours:AreaRows(locations, padding)
    local rows = {}
    local minimum = nil
    local maximum = nil
    local clusters = BuildClusters(UniquePoints(locations))
    local index = 1
    local total = table.getn(clusters)
    while index <= total do
        minimum, maximum = ScanHull(
            ExpandedHull(clusters[index], padding or HULL_PADDING),
            rows, minimum, maximum)
        index = index + 1
    end
    MergeRows(rows, minimum, maximum)
    return rows, minimum, maximum
end

-- Per-pixel coverage from the real shape, interpolated by the GPU.
--
-- A contour cell is only 1-2 screen pixels, so its colour follows the exact
-- signed distance between the cell centre and the rounded hulls rather than a
-- marching-squares mask. Distances are in "iso" cell units -- x in grid
-- cells, y in grid cells scaled by Y_SCALE -- so one unit is the same
-- on-screen length both ways.
--
-- Drawing one flat texture per cell cost about a thousand textures per area
-- and froze the map when a zone first drew. Along a row the distance changes
-- almost linearly, so each row is cut into the fewest pieces whose distances
-- stay within PROFILE_TOLERANCE of a straight line, and each piece is ONE
-- texture whose texcoords sweep the matching stretch of the profile strip:
-- the bilinear filter then evaluates the profile per pixel. A flat interior
-- run is one piece, and a piece identical to the one above extends it down.
local PROFILE_TOLERANCE = 0.06

-- Squared, so a cell takes one square root for its nearest edge only.
local function SegmentDistanceSquared(px, py, edge)
    local ax, ay = edge[1], edge[2]
    local dx, dy = edge[3] - ax, edge[4] - ay
    local lengthSquared = dx * dx + dy * dy
    local t = 0
    if lengthSquared > 0 then
        t = ((px - ax) * dx + (py - ay) * dy) / lengthSquared
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local ex = ax + dx * t - px
    local ey = ay + dy * t - py
    return ex * ex + ey * ey
end

-- One hull in iso units, with every edge bucketed into the rows whose slab
-- (row centre +- reach) it can touch, so a row only visits nearby edges.
local function IsoPolygon(polygon, reach)
    local cellPercent = MAP_SIZE / GRID
    local rows = {}
    local minY, maxY = nil, nil
    local total = table.getn(polygon)
    local index = 1
    while index <= total do
        local a = polygon[index]
        local b = polygon[index < total and index + 1 or 1]
        local edge = {
            a[1] / cellPercent, a[2] / cellPercent * Y_SCALE,
            b[1] / cellPercent, b[2] / cellPercent * Y_SCALE,
        }
        local low, high = edge[2], edge[4]
        if low > high then low, high = high, low end
        if not minY or low < minY then minY = low end
        if not maxY or high > maxY then maxY = high end
        local row = math.max(0, math.floor((low - reach) / Y_SCALE - 0.5))
        local last = math.min(GRID - 1, math.ceil((high + reach) / Y_SCALE - 0.5))
        while row <= last do
            rows[row] = rows[row] or {}
            table.insert(rows[row], edge)
            row = row + 1
        end
        index = index + 1
    end
    return { rows = rows, minY = minY, maxY = maxY }
end

-- For one hull and one row: its span on the row line, and the cell ranges
-- its nearby edges can colour (each edge's x extent inside the slab, widened
-- by `reach`), appended to `ranges`.
local function RowReach(near, y, reach, ranges)
    local left, right = nil, nil
    local index = 1
    local total = table.getn(near)
    while index <= total do
        local edge = near[index]
        local ay, by = edge[2], edge[4]
        if (ay > y) ~= (by > y) then
            local x = edge[1] + (y - ay) * (edge[3] - edge[1]) / (by - ay)
            if not left or x < left then left = x end
            if not right or x > right then right = x end
        end
        local low, high = ay, by
        if low > high then low, high = high, low end
        if high >= y - reach and low <= y + reach then
            local x1, x2 = edge[1], edge[3]
            if high > low then
                local slope = (edge[3] - edge[1]) / (by - ay)
                x1 = edge[1] + (math.max(low, y - reach) - ay) * slope
                x2 = edge[1] + (math.min(high, y + reach) - ay) * slope
            end
            if x1 > x2 then x1, x2 = x2, x1 end
            table.insert(ranges, {
                math.floor(x1 - reach - 0.5), math.ceil(x2 + reach - 0.5),
            })
        end
        index = index + 1
    end
    return left, right
end

-- Sorts and merges inclusive integer ranges.
local function MergeRanges(ranges)
    table.sort(ranges, SpanOrder)
    local merged = {}
    local index = 1
    local total = table.getn(ranges)
    while index <= total do
        local range = ranges[index]
        local previous = merged[table.getn(merged)]
        if previous and range[1] <= previous[2] + 1 then
            if range[2] > previous[2] then previous[2] = range[2] end
        else
            table.insert(merged, { range[1], range[2] })
        end
        index = index + 1
    end
    return merged
end

-- Cuts one contiguous run of clamped cell distances into straight pieces.
-- Each piece is anchored on its first cell and grows while one slope still
-- fits every cell within the tolerance (a narrowing slope window, so the
-- whole run costs one pass). Returns pieces as { firstCell, lastCell,
-- distanceAtLeftEdge, distanceAtRightEdge }; transparent cells are skipped.
local function LinearPieces(values, count, firstX, pieces)
    local start = 1
    while start <= count do
        if values[start] <= PROFILE_D_MIN then
            start = start + 1
        else
            local origin = values[start]
            local low, high = -1000000, 1000000
            local finish = start
            while finish + 1 <= count and values[finish + 1] > PROFILE_D_MIN do
                local offset = finish + 1 - start
                local value = values[finish + 1]
                local nextLow = (value - PROFILE_TOLERANCE - origin) / offset
                local nextHigh = (value + PROFILE_TOLERANCE - origin) / offset
                if nextLow > low then nextLow = nextLow else nextLow = low end
                if nextHigh < high then nextHigh = nextHigh else nextHigh = high end
                if nextLow > nextHigh then break end
                low, high = nextLow, nextHigh
                finish = finish + 1
            end
            local slope = 0
            if finish > start then
                slope = (low + high) / 2
            end
            local leftValue = Clamp(origin - slope * 0.5, PROFILE_D_MIN, PROFILE_D_MAX)
            local rightValue = Clamp(origin + slope * (finish - start + 0.5),
                PROFILE_D_MIN, PROFILE_D_MAX)
            table.insert(pieces, {
                firstX + start - 1, firstX + finish, leftValue, rightValue,
            })
            start = finish + 1
        end
    end
end

function AreaContours:AreaPolygons(locations, padding, reach)
    local polygons = {}
    local clusters = BuildClusters(UniquePoints(locations))
    local index = 1
    local total = table.getn(clusters)
    while index <= total do
        table.insert(polygons, IsoPolygon(
            ExpandedHull(clusters[index], padding or HULL_PADDING), reach or 0))
        index = index + 1
    end
    return polygons
end

-- Returns { left, top, right, bottom, distanceLeft, distanceRight } patches
-- in grid cells. The texture spans distanceLeft..distanceRight across its
-- width.
local function BeginProfileBuild(self, locations, padding)
    local patches = {}
    local reach = -PROFILE_D_MIN + 0.01
    local polygons = self:AreaPolygons(locations, padding, reach)
    local polygonTotal = table.getn(polygons)
    if polygonTotal == 0 then
        return { patches = patches, done = true }
    end
    local minY, maxY = nil, nil
    local index = 1
    while index <= polygonTotal do
        local poly = polygons[index]
        if not minY or poly.minY < minY then minY = poly.minY end
        if not maxY or poly.maxY > maxY then maxY = poly.maxY end
        index = index + 1
    end
    local firstRow = math.max(0, math.floor((minY - reach) / Y_SCALE - 0.5))
    local lastRow = math.min(GRID - 1, math.ceil((maxY + reach) / Y_SCALE - 0.5))
    return {
        patches = patches,
        reach = reach,
        polygons = polygons,
        polygonTotal = polygonTotal,
        active = {},
        row = firstRow,
        lastRow = lastRow,
        done = false,
    }
end

local function StepProfileBuild(build, rowBudget)
    if build.done then
        return true, build.patches
    end
    local processed = 0
    while build.row <= build.lastRow and processed < rowBudget do
        local row = build.row
        local reach = build.reach
        local polygons = build.polygons
        local polygonTotal = build.polygonTotal
        local y = (row + 0.5) * Y_SCALE
        local lefts, rights, nears = {}, {}, {}
        local bandRanges, cellRanges = {}, {}
        local index = 1
        while index <= polygonTotal do
            local near = polygons[index].rows[row]
            nears[index] = near
            if near then
                local left, right = RowReach(near, y, reach, bandRanges)
                lefts[index], rights[index] = left, right
                if left then
                    table.insert(cellRanges, {
                        math.ceil(left - 0.5), math.floor(right - 0.5),
                    })
                end
            end
            index = index + 1
        end
        bandRanges = MergeRanges(bandRanges)
        local rangeIndex = 1
        while rangeIndex <= table.getn(bandRanges) do
            table.insert(cellRanges, bandRanges[rangeIndex])
            rangeIndex = rangeIndex + 1
        end
        cellRanges = MergeRanges(cellRanges)

        local pieces = {}
        local bandIndex = 1
        rangeIndex = 1
        while rangeIndex <= table.getn(cellRanges) do
            local range = cellRanges[rangeIndex]
            local firstX = math.max(0, range[1])
            local last = math.min(GRID - 1, range[2])
            local values = {}
            local count = 0
            local x = firstX
            while x <= last do
                while bandRanges[bandIndex] and bandRanges[bandIndex][2] < x do
                    bandIndex = bandIndex + 1
                end
                local band = bandRanges[bandIndex]
                local value = PROFILE_D_MAX
                if band and x >= band[1] then
                    local centre = x + 0.5
                    local distance = nil
                    local polyIndex = 1
                    while polyIndex <= polygonTotal do
                        local near = nears[polyIndex]
                        if near then
                            local nearest = (PROFILE_D_MAX + reach) * (PROFILE_D_MAX + reach)
                            local edgeIndex = 1
                            local edgeTotal = table.getn(near)
                            while edgeIndex <= edgeTotal do
                                local d = SegmentDistanceSquared(centre, y, near[edgeIndex])
                                if d < nearest then nearest = d end
                                edgeIndex = edgeIndex + 1
                            end
                            nearest = math.sqrt(nearest)
                            local inside = lefts[polyIndex] and centre >= lefts[polyIndex]
                                and centre <= rights[polyIndex]
                            local signed = inside and nearest or -nearest
                            if not distance or signed > distance then distance = signed end
                        end
                        polyIndex = polyIndex + 1
                    end
                    value = Clamp(distance or PROFILE_D_MIN, PROFILE_D_MIN, PROFILE_D_MAX)
                end
                count = count + 1
                values[count] = value
                x = x + 1
            end
            LinearPieces(values, count, firstX, pieces)
            rangeIndex = rangeIndex + 1
        end

        local nextActive = {}
        local pieceIndex = 1
        while pieceIndex <= table.getn(pieces) do
            local piece = pieces[pieceIndex]
            local key = piece[1] .. ":" .. piece[2] .. ":"
                .. math.floor(piece[3] * 1000 + 0.5) .. ":" .. math.floor(piece[4] * 1000 + 0.5)
            local patch = build.active[key]
            if patch then
                patch[4] = row + 1
            else
                patch = { piece[1], row, piece[2], row + 1, piece[3], piece[4] }
                table.insert(build.patches, patch)
            end
            nextActive[key] = patch
            pieceIndex = pieceIndex + 1
        end
        build.active = nextActive
        build.row = row + 1
        processed = processed + 1
    end
    if build.row > build.lastRow then
        build.done = true
    end
    return build.done, build.patches
end

function AreaContours:ProfilePatches(locations, padding)
    local build = BeginProfileBuild(self, locations, padding)
    while not build.done do
        StepProfileBuild(build, GRID)
    end
    return build.patches
end

local function LayoutKey(quest, areaId, locations)
    local points = UniquePoints(locations)
    local ordered = {}
    local index = 1
    local total = table.getn(points)
    while index <= total do
        local point = points[index]
        ordered[index] = { x = point[1], y = point[2] }
        index = index + 1
    end
    local parts = {
        tostring(quest and (quest.questId or quest.titleKey or quest.title)),
        tostring(areaId),
    }
    index = 1
    while index <= total do
        local location = ordered[index]
        table.insert(parts, tostring(location.x) .. ":" .. tostring(location.y))
        index = index + 1
    end
    return table.concat(parts, "|"), ordered
end

function AreaContours:GetGroup(index)
    local entry = self.groups[index]
    if entry then return entry end
    local frame = Client.CreateWorldMapAreaGroup(index)
    if not frame then return nil end
    entry = { frame = frame, textures = {}, patches = {}, visible = 0 }
    self.groups[index] = entry
    self.groupPool[index] = frame
    return entry
end

local function HideTextures(entry, first)
    local index = first
    local total = table.getn(entry.textures)
    while index <= total do
        Client.HideObject(entry.textures[index])
        index = index + 1
    end
    entry.visible = first - 1
end

-- A drawn group is on screen only while it is pinned (the followed quest, or
-- every quest under "show all areas"), while its quest is hovered, or while
-- the reveal flash owns it. Every other drawn group keeps its patches built
-- and hidden, so a hover shows it without a rebuild.
local function ApplyShown(entry)
    if entry.pending then
        Client.HideObject(entry.frame)
    elseif entry.pinned or entry.hovered or entry.flashShown then
        Client.ReapplyWorldMapAreaGroup(entry.frame)
    else
        Client.HideObject(entry.frame)
    end
end

local function ApplyEntry(entry)
    local failures = 0
    local index = 1
    local total = table.getn(entry.patches)
    while index <= total do
        if not entry.textures[index] then
            entry.textures[index] = Client.CreateWorldMapAreaPatch(entry.frame)
        end
        index = index + 1
    end
    -- One guarded pass over the whole group; a patch it could not place (or
    -- the rest of the group, if the pass itself failed) takes the per-patch
    -- path, which reports and hides it individually.
    local placed = Client.PlaceWorldMapAreaPatches(entry.frame, entry.textures,
        entry.patches, total, entry.path, entry.red, entry.green, entry.blue)
    index = placed + 1
    while index <= total do
        local texture = entry.textures[index]
        local patch = entry.patches[index]
        if not texture or not Client.PlaceWorldMapAreaPatch(
            entry.frame, texture, entry.path,
            patch[1], patch[2], patch[3], patch[4],
            patch[5], patch[6], patch[7], patch[8],
            entry.red, entry.green, entry.blue) then
            failures = failures + 1
            if texture then Client.HideObject(texture) end
        end
        index = index + 1
    end
    HideTextures(entry, total + 1)
    ApplyShown(entry)
    return failures
end

-- Hover only changes the strip and tint, never a position.
local function RestyleEntry(entry)
    Client.RestyleWorldMapAreaPatches(entry.textures, entry.visible,
        entry.path, entry.red, entry.green, entry.blue)
    ApplyShown(entry)
    return 0
end

-- The strip u of one signed distance: texel centre 0 is PROFILE_D_MIN and
-- texel centre PROFILE_SIZE-1 is PROFILE_D_MAX, so the ends never filter past
-- the strip.
local function ProfileU(distance)
    local amount = (distance - PROFILE_D_MIN) / (PROFILE_D_MAX - PROFILE_D_MIN)
    return (0.5 + Clamp(amount, 0, 1) * (PROFILE_SIZE - 1)) / PROFILE_SIZE
end

local function BuildPatchRecords(mapContext, areaId, report, patches)
    local records = {}
    local index = 1
    local total = table.getn(patches)
    while index <= total do
        local patch = patches[index]
        local left = math.max(0, patch[1])
        local top = math.max(0, patch[2])
        local right = math.min(GRID, patch[3])
        local bottom = math.min(GRID, patch[4])
        if right > left and bottom > top then
            local x1, y1 = mapContext:DatabaseToCurrentMap(
                areaId, left * MAP_SIZE / GRID,
                top * MAP_SIZE / GRID, report)
            local x2, y2 = mapContext:DatabaseToCurrentMap(
                areaId, right * MAP_SIZE / GRID,
                bottom * MAP_SIZE / GRID, report)
            if x1 and y1 and x2 and y2 and x2 > x1 and y2 > y1 then
                table.insert(records, {
                    x1, y1, x2, y2, ProfileU(patch[5]), ProfileU(patch[6]),
                    0.25, 0.75,
                })
            end
        end
        index = index + 1
    end
    return records
end

function AreaContours:BeginPass(enabled)
    self.enabled = enabled and true or false
    self.nextGroup = 1
    if not self.enabled then
        self:HideAll()
    end
end

-- Picks the contour texture and tint for one group: the hover style while its
-- quest is hovered (and it has one), its own base style otherwise. Returns
-- whether the style changed, so an unchanged group is never restyled.
local function SelectStyle(entry)
    local style = entry.hovered and entry.hoverStyle or entry.baseStyle
    local styleKey = style.path .. "|" .. tostring(style.red) .. "|"
        .. tostring(style.green) .. "|" .. tostring(style.blue)
    local changed = entry.styleKey ~= styleKey
    entry.path = style.path
    entry.red, entry.green, entry.blue = style.red, style.green, style.blue
    entry.styleKey = styleKey
    return changed
end

-- `neutral` draws the tintable white contour in red/green/blue; otherwise the
-- Forever texture keeps its own baked colour. hoverRed/Green/Blue, when given,
-- are the neutral tint the group takes while its quest is hovered. `pinned`
-- keeps the group on screen; an unpinned one shows only while hovered.
function AreaContours:DrawQuest(quest, locations, areaId, report, mapContext,
    red, green, blue, neutral, hoverRed, hoverGreen, hoverBlue, pinned)
    if not self.enabled or not quest or not mapContext
        or table.getn(locations or {}) == 0 then
        return 0
    end
    local index = self.nextGroup
    local entry = self:GetGroup(index)
    if not entry then return 1 end
    local key, ordered = LayoutKey(quest, areaId, locations)
    if neutral then
        entry.baseStyle = { path = Client.WORLD_MAP_AREA_CONTOUR_NEUTRAL_TEXTURE,
            red = red, green = green, blue = blue }
    else
        entry.baseStyle = { path = Client.WORLD_MAP_AREA_CONTOUR_TEXTURE,
            red = 1, green = 1, blue = 1 }
    end
    entry.hoverStyle = nil
    if hoverRed then
        entry.hoverStyle = { path = Client.WORLD_MAP_AREA_CONTOUR_NEUTRAL_TEXTURE,
            red = hoverRed, green = hoverGreen, blue = hoverBlue }
    end
    entry.hovered = self.hoverTest and self.hoverTest(quest) and true or false
    entry.pinned = pinned and true or false
    entry.flashShown = nil
    local geometryChanged = entry.layoutKey ~= key
    local styleChanged = SelectStyle(entry)
    entry.frame.unrealQuestQuest = quest
    entry.frame.unrealQuestAreaContour = true
    if not entry.frame.unrealQuestFlashActive then
        Client.SetWorldMapPinAlpha(entry.frame, 1)
    end
    if geometryChanged then
        entry.layoutKey = key
        local cached = self.patchCache[key]
        if cached then
            entry.pending = nil
            entry.patches = BuildPatchRecords(mapContext, areaId, report, cached)
        else
            entry.pending = {
                key = key, locations = ordered, areaId = areaId,
                report = report, mapContext = mapContext,
            }
            self:QueueBuild(entry)
        end
    end
    local failures = 0
    if entry.pending then
        ApplyShown(entry)
    elseif geometryChanged or styleChanged then
        failures = ApplyEntry(entry)
    else
        ApplyShown(entry)
    end
    self.nextGroup = index + 1
    return failures
end

local function StoreLayout(self, key, patches)
    if self.patchCache[key] then
        return self.patchCache[key]
    end
    if self.patchCacheCount >= PATCH_CACHE_LIMIT then
        self.patchCache = {}
        self.patchCacheCount = 0
    end
    self.patchCache[key] = patches
    self.patchCacheCount = self.patchCacheCount + 1
    return patches
end

-- One in-progress build is shared by the world map and minimap. Both may ask
-- for the same newly accepted quest before either surface has cached it.
function AreaContours:BeginLayoutBuild(key, ordered)
    local cached = self.patchCache[key]
    if cached then
        return nil, cached
    end
    local build = self.layoutBuilds[key]
    if not build then
        build = BeginProfileBuild(self, ordered, HULL_PADDING)
        build.key = key
        self.layoutBuilds[key] = build
    end
    return build, nil
end

function AreaContours:StepLayoutBuild(build, rowBudget)
    if not build then
        return false, nil
    end
    local cached = self.patchCache[build.key]
    if cached then
        return true, cached
    end
    local done, patches = StepProfileBuild(
        build, rowBudget or BUILD_ROWS_PER_TICK)
    if done then
        self.layoutBuilds[build.key] = nil
        patches = StoreLayout(self, build.key, patches)
        return true, patches
    end
    return false, nil
end

local function FinishPending(entry, patches)
    local pending = entry.pending
    if not pending then
        return 0
    end
    entry.patches = BuildPatchRecords(
        pending.mapContext, pending.areaId, pending.report, patches)
    entry.pending = nil
    return ApplyEntry(entry)
end

-- Synchronous fallback for an environment with no shared driver.
function AreaContours:BuildPending(entry)
    local pending = entry.pending
    if not pending then
        return 0
    end
    return FinishPending(entry,
        self:BuildLayout(pending.key, pending.locations))
end

function AreaContours:StepPending(entry)
    local pending = entry.pending
    if not pending then
        return true, 0
    end
    local patches = self.patchCache[pending.key]
    if not patches then
        local build = pending.build
        if not build then
            build, patches = self:BeginLayoutBuild(
                pending.key, pending.locations)
            pending.build = build
        end
        if not patches then
            local done
            done, patches = self:StepLayoutBuild(
                build, BUILD_ROWS_PER_TICK)
            if not done then
                return false, 0
            end
        end
    end
    return true, FinishPending(entry, patches)
end

local function RunBuildQueue()
    local contours = AreaContours
    local built = 0
    if table.getn(contours.buildQueue) > 0 then
        local entry = table.remove(contours.buildQueue, 1)
        entry.queued = nil
        if entry.pending then
            local done = contours:StepPending(entry)
            if done then
                built = 1
            else
                entry.queued = true
                table.insert(contours.buildQueue, entry)
            end
        end
    end
    if table.getn(contours.buildQueue) == 0 then
        local driver = UQ:GetModule("Driver")
        if driver then
            driver:Unschedule("map.contours")
        end
    end
    return built
end

function AreaContours:QueueBuild(entry)
    local driver = UQ:GetModule("Driver")
    if not driver or not Client.Now() then
        -- No shared driver to spread the work: build now, as before.
        return self:BuildPending(entry)
    end
    if not entry.queued then
        entry.queued = true
        table.insert(self.buildQueue, entry)
    end
    driver:Schedule("map.contours", 0, RunBuildQueue)
    return 0
end

-- Drops a group's queued build, so a group that left the map is never built
-- (and shown) after the fact. Its layout is forgotten so it rebuilds cleanly.
local function CancelPending(entry)
    if entry.pending then
        entry.pending = nil
        entry.layoutKey = nil
    end
end

function AreaContours:FinishPass()
    local index = self.nextGroup
    local total = table.getn(self.groups)
    while index <= total do
        CancelPending(self.groups[index])
        Client.HideObject(self.groups[index].frame)
        index = index + 1
    end
    self.visibleCount = self.enabled and (self.nextGroup - 1) or 0
end

function AreaContours:HideAll()
    local index = 1
    local total = table.getn(self.groups)
    while index <= total do
        CancelPending(self.groups[index])
        Client.HideObject(self.groups[index].frame)
        index = index + 1
    end
    self.visibleCount = 0
end

function AreaContours:Reapply(resized)
    local index = 1
    while index <= self.visibleCount do
        local entry = self.groups[index]
        if entry.pending then
            ApplyShown(entry)
        elseif resized then
            ApplyEntry(entry)
        else
            ApplyShown(entry)
        end
        index = index + 1
    end
end

-- Hover recolours a quest's own contour instead of fading everyone else's.
-- `test(quest)` answers whether that quest is hovered; it is kept so a rebuild
-- draws a still-hovered quest in its hover style straight away.
function AreaContours:SetHoverTest(test)
    self.hoverTest = test
end

-- Restyles, shows or hides only the groups whose hovered state changed since
-- the last call.
function AreaContours:RefreshHover()
    local failures = 0
    local index = 1
    while index <= self.visibleCount do
        local entry = self.groups[index]
        local quest = entry and entry.frame.unrealQuestQuest
        local hovered = quest and self.hoverTest and self.hoverTest(quest) and true or false
        if entry and entry.baseStyle and entry.hovered ~= hovered then
            entry.hovered = hovered
            if SelectStyle(entry) then
                failures = failures + RestyleEntry(entry)
            else
                ApplyShown(entry)
            end
        end
        index = index + 1
    end
    return failures
end

function AreaContours:GetGroupPool()
    return self.groupPool
end

function AreaContours:GetVisibleCount()
    return self.visibleCount or 0
end

-- A hidden (unpinned) group of the revealed quest is shown for the flash; the
-- rebuild the flash ends with draws it hidden again.
function AreaContours:AppendFlashTargets(targets, questId)
    local added = 0
    local index = 1
    while index <= self.visibleCount do
        local entry = self.groups[index]
        local frame = entry.frame
        local quest = frame and frame.unrealQuestQuest
        if quest and quest.questId == questId then
            entry.flashShown = true
            ApplyShown(entry)
            table.insert(targets, frame)
            added = added + 1
        end
        index = index + 1
    end
    return added
end

-- Shared with Map/MinimapAreas.lua, which draws the same shapes on the
-- minimap. Both read one geometry cache, so a quest area is never computed
-- twice for the two maps.
AreaContours.GRID = GRID
AreaContours.BUILD_ROWS_PER_TICK = BUILD_ROWS_PER_TICK

-- The cached grid patches of one quest layout, or nil plus what BuildLayout
-- needs to compute them.
function AreaContours:LayoutPatches(quest, areaId, locations)
    local key, ordered = LayoutKey(quest, areaId, locations)
    return self.patchCache[key], key, ordered
end

-- Computes (and caches) one layout's grid patches.
function AreaContours:BuildLayout(key, ordered)
    local patches = self.patchCache[key]
    if patches then
        return patches
    end
    local build
    build, patches = self:BeginLayoutBuild(key, ordered)
    while not patches do
        local done
        done, patches = self:StepLayoutBuild(build, GRID)
        if not done then
            patches = nil
        end
    end
    return patches
end

-- The profile strip's u for one signed distance (see ProfileU above).
function AreaContours.ProfileU(distance)
    return ProfileU(distance)
end
