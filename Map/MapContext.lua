--[[
UnrealQuest / Map/MapContext.lua

Map identification and the verified current-zone coordinate boundary.

Measured evidence now establishes the conservative first slice: after the map
is initialized to the player zone, GetPlayerMapPosition returns non-zero UVs;
GetZoneText resolves Elwynn Forest uniquely to area ID 12; and an addon-owned
coloured child renders on the fullscreen map while its view changes. The tile
file name "Elwynn" still does not itself join to "Elwynn Forest", and child
area/continent transforms remain unverified. This module therefore converts
only direct coordinates in the player's uniquely resolved current area, and
only while the current map view can project the player.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local MapContext = UQ:NewModule("MapContext")

MapContext.zoneNameIndex = nil

-- Set true after the first attempt (successful or not) to prime the client's
-- map subsystem out of its post-login/reload cold state. See GetCurrentZoneView.
MapContext.primeAttempted = false

local function Database()
    return UQ:GetModule("Database")
end

-- Reverse index from normalized area name to area ID, built from the static
-- database. Built on demand: nothing polls it.
function MapContext:BuildZoneNameIndex()
    if self.zoneNameIndex then
        return self.zoneNameIndex
    end
    local database = Database()
    if not database or not database.available then
        return nil
    end

    local names = database:GetZoneNames()
    if not names then
        return nil
    end

    local index = {}
    for zoneId, name in pairs(names) do
        local key = UQ.NameKey(name)
        if key then
            local bucket = index[key]
            if not bucket then
                bucket = {}
                index[key] = bucket
            end
            table.insert(bucket, zoneId)
        end
    end
    self.zoneNameIndex = index
    return index
end

-- Best-effort area ID for a client-supplied name. Returns the ID and how it was
-- reached, or nil plus the reason. Callers must treat a hit as a hypothesis.
function MapContext:ResolveAreaId(name)
    if type(name) ~= "string" or name == "" then
        return nil, "noName"
    end
    local index = self:BuildZoneNameIndex()
    if not index then
        return nil, "noDatabase"
    end
    local key = UQ.NameKey(name)
    if not key then
        return nil, "noName"
    end
    local bucket = index[key]
    if not bucket then
        return nil, "noMatch"
    end
    if table.getn(bucket) == 1 then
        return bucket[1], "unique"
    end

    -- 47 names in the bundled zone table are carried by more than one area,
    -- and one of them is a zone the player can stand in: "Westfall" is both
    -- area 40 and area 206, so the whole pin layer resolved nothing there and
    -- drew nothing. The tiebreak comes from the data itself -- only a zone
    -- with its own map has a yard span in the minimap table, so a colliding
    -- interior, dungeon wing or stretch of sea drops out. Applied only after
    -- a true collision, and only when it leaves exactly one candidate:
    -- anything else stays "ambiguous" and the caller keeps refusing to guess.
    local database = Database()
    if database then
        local spanned = nil
        local spannedCount = 0
        local index = 1
        local total = table.getn(bucket)
        while index <= total do
            if database:GetZoneYards(bucket[index]) then
                spanned = bucket[index]
                spannedCount = spannedCount + 1
            end
            index = index + 1
        end
        if spannedCount == 1 then
            return spanned, "spanDisambiguated"
        end
    end
    return nil, "ambiguous"
end

-- Is this name one of the zone names the CLIENT itself lists for the player's
-- continent?
--
-- This is the measured discriminator between "the player is standing in a zone"
-- and "the player is standing in a room the client is calling a zone". Probe
-- zoneindoor, 2026-08-29, Echo Ridge Mine in Elwynn Forest:
--
--            zoneText        realZoneText    subZoneText       in GetMapZones
--   outside  Elwynn Forest   Elwynn Forest   Echo Ridge Mine   yes
--   inside   Echo Ridge Mine Echo Ridge Mine (empty)           no
--
-- Note what happens to the subzone indoors: it goes EMPTY and the room is
-- promoted to the zone, which is the opposite of the shape a "zone and subzone
-- name the same place" test assumes. Membership in the client's own zone list
-- is what actually separates the two rows, and it does not care which of the
-- two name calls produced the string.
--
-- Returns true, false, or nil for "the list could not be read" -- nil is not
-- false, and a caller must not conclude "indoors" from it.
function MapContext:IsListedZoneName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local continent = Client.GetCurrentMapContinent()
    if type(continent) ~= "number" then
        return nil
    end
    local list = Client.GetMapZoneNames(continent)
    if type(list) ~= "table" then
        return nil
    end
    local total = table.getn(list)
    if total == 0 then
        return nil
    end
    local key = UQ.NameKey(name)
    local index = 1
    while index <= total do
        if UQ.NameKey(list[index]) == key then
            return true
        end
        index = index + 1
    end
    return false
end

-- Does this area have a map of its own?
--
-- The SECOND, client-independent half of the indoor test above, and the reason
-- an unreadable zone list can no longer empty the tracker. Database/minimap.lua
-- carries a yard span for exactly the areas this client draws a zone map for:
-- Elwynn Forest (12) has one; Echo Ridge Mine (34) and Northshire Valley (9),
-- both real areas the client will happily name as the zone, do not.
-- ResolveAreaId already leans on that span to break name collisions -- this is
-- the same fact asked as a question about one area.
--
-- It answers what IsListedZoneName answers, from a completely different
-- source: static bundled data rather than a client call that is documented to
-- come back empty until the map subsystem has been touched this session. So
-- when the client will not hand over its zone list, GetStandingZone can still
-- tell a room from a zone instead of filtering the tracker on a room name.
--
-- Returns true, false, or nil for "the question could not be asked" -- no
-- database, or a name that resolved to no area at all.
function MapContext:HasOwnMap(areaId)
    local database = Database()
    if type(areaId) ~= "number" or not database or not database.available then
        return nil
    end
    return database:GetZoneYards(areaId) ~= nil
end

-- The outermost zone an area sits inside, for a caller holding an area that
-- came from where the player is STANDING rather than from a map view.
--
-- Walking Database/zones.lua's parent link turns Northshire Valley back into
-- Elwynn Forest and Deathknell back into Tirisfal Glades. It does NOT rescue
-- every indoor case -- probe zoneindoor measured Echo Ridge Mine resolving to
-- area 34, which has no parent row at all -- so this is one route among
-- several in GetStandingZone below, never the answer on its own.
--
-- Returns the enclosing area ID and its localized name, or nil when the area is
-- already top level or the table files it under nothing. The walk is bounded
-- because zones.lua is data: a cycle in it must not hang a caller that runs on
-- the tracker's 0.4s refresh.
local MAX_PARENT_DEPTH = 4

function MapContext:ResolveEnclosingArea(areaId)
    local database = Database()
    if type(areaId) ~= "number" or not database or not database.available then
        return nil
    end
    local currentId = areaId
    local resolvedId, resolvedName = nil, nil
    local depth = 0
    while depth < MAX_PARENT_DEPTH do
        local parentId = database:GetParentZoneId(currentId)
        if not parentId then
            break
        end
        local parentName = database:GetZoneName(parentId)
        if type(parentName) == "string" and parentName ~= "" then
            resolvedId, resolvedName = parentId, parentName
        end
        currentId = parentId
        depth = depth + 1
    end
    if not resolvedId or not resolvedName then
        return nil
    end
    return resolvedId, resolvedName
end

-- The dungeon or raid this area is the interior of, or nil.
--
-- Delegated to Data/Database.lua, like every other bundled-table lookup in
-- this file. Two callers want it: GetStandingZone below, as the second of the
-- two sources that can tell a dungeon from a mine, and the tracker's zone
-- filter, which needs the map ID itself to ask which quests have work here.
function MapContext:GetInstanceMapForArea(areaId)
    local database = Database()
    if not database or not database.available or type(areaId) ~= "number" then
        return nil
    end
    return database:GetInstanceMapForArea(areaId)
end

-- Which zone is the player STANDING in -- answered so that walking through a
-- door does not change it.
--
-- This is deliberately not GetCurrentZoneView. That question is about the map
-- view that is open, and the tracker's current-zone filter has to keep working
-- with the map closed. This one starts from the player's own position and only
-- reaches for the map when the position's answer is provably a room.
--
-- Returns the zone name, its area ID and how it was reached, or nil plus a
-- reason. Routes, in order:
--
--   "standing"   the position name is one of the continent's listed zones.
--                The ordinary outdoor answer.
--   "standingSpan" the client would not list its zones, but the bundled table
--                gives the resolved area a map of its own, which only a real
--                zone has. The same conclusion as "standing" reached from the
--                static data, and it updates the memory too.
--   "instance"   the player is inside a dungeon or raid, so the instance's own
--                name IS the zone. Reached from the client's IsInInstance, or
--                -- when this client has no such global -- from a name the two
--                zone tests already refused that Database/instances.lua names
--                as an instance. Ahead of every recovery below because those
--                all answer with an OUTDOOR zone, which is the one thing a
--                dungeon interior is not. Filtering a dungeon on the outdoor
--                zone the player walked in from is what used to leave the
--                tracker listing the entire quest log inside instances.
--   "parent"     Database/zones.lua files the room's area under a zone. Static
--                data and exact, but absent for most caves and every inn.
--   "remembered" the last proven-zone answer this session. Walking indoors does
--                not change which zone the building is in, so the name from one
--                tick before the door is the answer. Fails only for a player
--                who logged in or reloaded already inside.
--   "mapZone"    the viewed map's own zone name, measured holding "Elwynn
--                Forest" throughout the Echo Ridge Mine sample. Last because it
--                follows a player who deliberately browses another zone's map,
--                which the three routes above cannot do.
--
-- nil means every route declined, and the caller must degrade to not filtering
-- rather than to filtering on a guess.
function MapContext:GetStandingZone()
    local name = Client.GetRealZoneText()
    if not name then
        name = Client.GetZoneText()
    end
    if type(name) ~= "string" or name == "" then
        return nil, nil, "noName"
    end

    local areaId = self:ResolveAreaId(name)

    -- Before the zone tests, because it outranks every one of their outcomes:
    -- a dungeon's name is not in the client's zone list and its area has no map
    -- of its own, which is exactly the shape a mine has, and the two want
    -- opposite answers. Only the client can see a portal the bundled table has
    -- no row for, so its verdict is taken first and on its own.
    --
    -- The memory of the last outdoor zone is deliberately NOT written here: it
    -- is what the player walks back out into.
    local inInstance = Client.IsInInstance()
    if inInstance == true then
        return name, areaId, "instance"
    end

    -- Two independent readings of the same question, because either source can
    -- decline. The client's zone list is the measured discriminator, but it is
    -- documented to be empty until the map subsystem has been touched this
    -- session -- and a session that never touched it used to fall straight
    -- through to "unlistable", i.e. to filtering the tracker on whatever the
    -- client called the room, with the memory below never populated either
    -- because only a listed name writes it. HasOwnMap answers from the bundled
    -- table instead, so the fallthrough now survives only a name that resolves
    -- to no area at all.
    local how = nil
    local listed = self:IsListedZoneName(name)
    if listed == true then
        how = "standing"
    elseif listed == nil then
        local ownMap = self:HasOwnMap(areaId)
        if ownMap == true then
            listed, how = true, "standingSpan"
        elseif ownMap == false then
            listed = false
        end
    end

    if listed ~= false then
        -- true, or nil for "neither source would answer" -- with no way to tell
        -- indoors from outdoors, the name is used exactly as it was before this
        -- route existed. Only a proven zone updates the memory.
        if listed == true then
            self.standingZoneName = name
            self.standingZoneArea = areaId
        end
        return name, areaId, how or "unlistable"
    end

    -- The second source, for a client with no IsInInstance at all. Placed here
    -- rather than beside the client call above so it can only ever see a name
    -- both zone tests have already refused: an outdoor area that merely shares
    -- an instance's name -- Zul'Gurub is a Stranglethorn subzone too -- is
    -- unreachable, because the player standing there is in a listed zone.
    if inInstance ~= false and self:GetInstanceMapForArea(areaId) then
        return name, areaId, "instance"
    end

    if areaId then
        local parentId, parentName = self:ResolveEnclosingArea(areaId)
        if parentId and parentName then
            return parentName, parentId, "parent"
        end
    end

    if self.standingZoneName then
        return self.standingZoneName, self.standingZoneArea, "remembered"
    end

    local report = self:InspectPrimed()
    if report and type(report.zoneIndex) == "number" and report.zoneIndex > 0
        and type(report.mapZoneName) == "string" and report.mapZoneName ~= "" then
        return report.mapZoneName, report.areaIdFromMapZone, "mapZone"
    end

    return nil, nil, "indoorUnresolved"
end

-- Snapshot of everything the client will tell us about the current map, with
-- the database-side resolution attempts alongside. Purely observational.
function MapContext:Inspect()
    local report = {}

    report.mapFile, report.tileHeight, report.tileWidth = Client.GetCurrentMapFile()
    report.continent = Client.GetCurrentMapContinent()
    report.zoneIndex = Client.GetCurrentMapZone()
    report.mapZoneName = Client.GetMapZoneName(report.continent, report.zoneIndex)
    report.zoneText = Client.GetZoneText()
    report.realZoneText = Client.GetRealZoneText()
    report.subZoneText = Client.GetSubZoneText()

    local x, y = Client.GetPlayerMapPosition("player")
    report.playerX = x
    report.playerY = y

    report.areaIdFromMapFile, report.areaIdFromMapFileHow = self:ResolveAreaId(report.mapFile)
    report.areaIdFromZoneText, report.areaIdFromZoneTextHow = self:ResolveAreaId(report.zoneText)
    report.areaIdFromRealZoneText, report.areaIdFromRealZoneTextHow =
        self:ResolveAreaId(report.realZoneText)
    report.areaIdFromMapZone, report.areaIdFromMapZoneHow =
        self:ResolveAreaId(report.mapZoneName)

    -- The one area every consumer reads, resolved from the most trustworthy
    -- name available.
    --
    -- The viewed map's own zone name comes first because it is the only one
    -- that cannot be shadowed by where the player happens to be standing.
    -- GetZoneText was measured returning "Brill Town Hall" -- a real area
    -- (2118) in the bundled table, with no quest data of its own -- while the
    -- Tirisfal map was open, and the layer duly matched its quests against a
    -- town hall, found nothing and drew an empty map. GetRealZoneText is the
    -- second choice for the same reason it is pfQuest's minimap route, and
    -- GetZoneText last, which is the behaviour this had before.
    report.areaId = report.areaIdFromMapZone
    report.areaIdHow = report.areaIdFromMapZoneHow
    if not report.areaId then
        report.areaId = report.areaIdFromRealZoneText
        report.areaIdHow = report.areaIdFromRealZoneTextHow
    end
    if not report.areaId then
        report.areaId = report.areaIdFromZoneText
        report.areaIdHow = report.areaIdFromZoneTextHow
    end

    local database = Database()
    if database and report.areaId then
        report.areaName = database:GetZoneName(report.areaId)
        report.zoneTransform = database:GetZoneTransform(report.areaId)
        report.zoneYards = database:GetZoneYards(report.areaId)
    end

    return report
end

-- Returns the uniquely resolved player area only when the selected map view
-- can project the player. A continent or another-zone view returns nil and the
-- pin layer hides its pool rather than guessing a transform.
--
-- GetPlayerMapPosition alone does not detect a zoomed-out view: this client
-- projects the player's blue arrow onto the continent map too, whenever the
-- viewed continent is the player's own, so playerX/playerY stay non-nil while
-- zoomed out to Eastern Kingdoms and the direct-current-zone percentages were
-- being drawn straight onto the continent canvas -- reported 2026-08-23 as
-- every marker surviving a zoom-out. GetCurrentMapZone is documented
-- (OFFICIAL_CLIENT_DOCUMENTATION, capability mapZoomLevel) to return 0
-- specifically when no individual zone is selected, i.e. a continent or world
-- view, so that is checked first and independently of the player-projection
-- guard below.
--
-- zoneIndex == 0 is ambiguous on its own: immediately after login/reload,
-- before this client's map subsystem has been touched this session, it reads
-- the identical 0/nil signature as a genuine continent view (confirmed
-- 2026-08-20, "Current-zone identification"). Left alone, the whole pin layer
-- (world map, minimap, HUD waypoint) stays hidden on the very first map open
-- until something coincidentally primes it. Probe mapcoldstart (2026-08-23)
-- confirmed one Client.SetMapToCurrentZone() call resolves that exact cold
-- signature -- zoneIndex 0, mapFile nil, player 0,0 -- into a real view, even
-- called before WorldMapFrame was ever shown. Priming is attempted at most
-- once per session (primeAttempted), so it can never fight a player who later
-- deliberately zooms out to browse a continent -- that zoneIndex 0 is left
-- alone and correctly hides the layer.
function MapContext:InspectPrimed()
    local report = self:Inspect()
    -- Never while a view this module parked is standing. SetMapToCurrentZone
    -- is precisely the call that would undo it, the cold signature is
    -- reachable from a deliberately moved view (a continent layer reports
    -- zoneIndex 0 and GetMapInfo nil by definition), and priming is a
    -- once-per-session one-shot -- so letting it fire here would yank the map
    -- home on some sessions and not others, which is exactly the kind of
    -- intermittency it was added to remove.
    if (not report.zoneIndex or report.zoneIndex == 0) and not report.mapFile
        and not self.primeAttempted and not self.parkedAreaId then
        self.primeAttempted = true
        if Client.SetMapToCurrentZone() then
            report = self:Inspect()
        end
    end
    return report
end

function MapContext:GetCurrentZoneView()
    local report = self:InspectPrimed()
    if not report.zoneIndex or report.zoneIndex == 0 then
        return nil, report, "continentView"
    end
    if not report.playerX or not report.playerY then
        return nil, report, "playerNotOnView"
    end
    if not report.areaId then
        return nil, report, report.areaIdHow or "areaUnresolved"
    end
    report.viewedAreaId = report.areaId
    return report.areaId, report, report.areaIdHow
end

-- The area the MAP is showing, whether or not the player is standing in it.
--
-- GetCurrentZoneView above answers a different question -- "which zone is the
-- player in, and can this view project them" -- and the minimap layer and the
-- HUD waypoint must keep asking that one, because both measure offsets from
-- the player's own position and a foreign zone's coordinates would be measured
-- from the wrong origin. The world map has no such dependency: it converts
-- database percentages straight to UVs on the canvas it is drawing, so it can
-- serve any zone whose map is open.
--
-- The distinction rests entirely on which NAME the area was resolved from.
-- GetMapZones/GetCurrentMapZone name the zone the map view is showing and
-- nothing the player does can shadow that, so it is the only route that stays
-- correct for a foreign zone. GetRealZoneText and GetZoneText name where the
-- PLAYER is, and Inspect falls back to them when the map-zone route is empty
-- -- which the documentation says it is until the map subsystem has been
-- touched this session. Those two are therefore accepted only while the view
-- projects the player, i.e. exactly the case where they agree with the view
-- anyway. That fallback is what preserves the previous behaviour when
-- GetMapZones returns nothing; it is never what draws a foreign zone.
--
-- A continent or world view is still refused: zoneIndex 0 means no individual
-- zone is selected, so there is no area whose percentages could be converted.
function MapContext:GetViewedZone()
    local report = self:InspectPrimed()
    if not report.zoneIndex or report.zoneIndex == 0 then
        return nil, report, "continentView"
    end
    if report.areaIdFromMapZone then
        report.viewedAreaId = report.areaIdFromMapZone
        return report.viewedAreaId, report, report.areaIdFromMapZoneHow
    end
    if not report.playerX or not report.playerY then
        return nil, report, "viewedZoneUnresolved"
    end
    if not report.areaId then
        return nil, report, report.areaIdHow or "areaUnresolved"
    end
    report.viewedAreaId = report.areaId
    return report.areaId, report, report.areaIdHow
end

-- Showing another zone -------------------------------------------------------
--
-- Everything above answers "what is the map showing". This answers the
-- opposite: make it show a named area, so a quest whose turn-in or objectives
-- are in another zone can be looked at instead of merely described in chat.
--
-- The world map layer already draws whichever zone the map is showing
-- (Map/WorldMapPins.lua, GetViewedZone above), so moving the view is the
-- whole feature -- no foreign-zone transform is involved and none is assumed.

-- The zone list the client loads is per continent, and the bundled data does
-- not record which continent an area is on, so the lists themselves are the
-- only route. 1 Kalimdor, 2 Eastern Kingdoms, per the client's own reference
-- for SetMapZoom/GetCurrentMapContinent; 0 is the cosmic layer and has no
-- zones to index into.
local MAP_CONTINENTS = { 1, 2 }

-- The 1-based index of an area in the zone list the client currently has
-- loaded, or nil.
--
-- Matching goes through ResolveAreaId rather than comparing strings, so the
-- client's own localized zone name never has to be spelled the same way as
-- the bundled table's -- the same join every other route in this module rests
-- on, and the reason this works on a Russian or Chinese client without a
-- second name table.
function MapContext:ZoneIndexForArea(areaId, continent)
    if type(areaId) ~= "number" or type(continent) ~= "number" then
        return nil
    end
    local list = Client.GetMapZoneNames(continent)
    if type(list) ~= "table" then
        return nil
    end
    local index = 1
    local total = table.getn(list)
    while index <= total do
        if self:ResolveAreaId(list[index]) == areaId then
            return index
        end
        index = index + 1
    end
    return nil
end

-- Takes the world map to the first area in `areaIds` this client can show.
--
-- Returns the area now being viewed and how it was reached -- "alreadyViewed"
-- when the map was already on one of them and nothing was touched, "switched"
-- when the view was moved -- or nil plus a reason.
--
-- Order of business, and each step is there for a reason:
--
--   * The zone already in view wins outright. A caller that could draw
--     nothing here has a problem the map view cannot fix (a quest hidden from
--     the map, an area with no coordinate), and moving the map would replace
--     an honest empty answer with a wrong zone.
--   * The player's own continent is searched first, and its list is read
--     WITHOUT selecting anything: the map is already on that continent, so
--     the loaded list is already the right one and the common
--     same-continent case costs no visible zoom-out at all.
--   * Only a miss reaches for the other continent, and that one must be
--     selected before its list can be read -- the client's reference says
--     GetMapZones ignores its argument and answers for the SELECTED
--     continent, which is also why pfQuest's own {GetMapZones(cid)} loop over
--     both continents cannot work here (reference only; not this addon's
--     source).
--   * A search that found nothing puts the view back on the player's own
--     zone. Leaving it parked on a continent layer would hide the entire pin
--     layer (GetCurrentMapZone 0) as a side effect of a lookup that failed.
function MapContext:ShowAreas(areaIds)
    if type(areaIds) ~= "table" then
        return nil, "noAreas"
    end
    local total = table.getn(areaIds)
    if total == 0 then
        return nil, "noAreas"
    end

    local viewed = self:GetViewedZone()
    if viewed then
        local index = 1
        while index <= total do
            if areaIds[index] == viewed then
                return viewed, "alreadyViewed"
            end
            index = index + 1
        end
    end

    local selected = Client.GetCurrentMapContinent()
    local startContinent = selected
    local continents = {}
    if type(selected) == "number" and selected > 0 then
        table.insert(continents, selected)
    end
    local listIndex = 1
    local listTotal = table.getn(MAP_CONTINENTS)
    while listIndex <= listTotal do
        if MAP_CONTINENTS[listIndex] ~= startContinent then
            table.insert(continents, MAP_CONTINENTS[listIndex])
        end
        listIndex = listIndex + 1
    end

    local moved = false
    local continentIndex = 1
    local continentTotal = table.getn(continents)
    while continentIndex <= continentTotal do
        local continent = continents[continentIndex]
        local readable = true
        if continent ~= selected then
            readable = Client.SetWorldMapView(continent)
            if readable then
                selected = continent
                moved = true
            end
        end
        if readable then
            local index = 1
            while index <= total do
                local zoneIndex = self:ZoneIndexForArea(areaIds[index], continent)
                if zoneIndex and Client.SetWorldMapView(continent, zoneIndex) then
                    moved = true
                    -- Read the view back rather than trust the call. The
                    -- two-argument SetMapZoom is DOCUMENTED here, never
                    -- probed, and pcall returning cleanly says only that it
                    -- did not error. Reporting "opened that zone's map" over
                    -- a map that never moved is worse than reporting that it
                    -- could not be opened, so the claim is measured before it
                    -- is made.
                    if self:GetViewedZone() == areaIds[index] then
                        return areaIds[index], "switched"
                    end
                end
                index = index + 1
            end
        end
        continentIndex = continentIndex + 1
    end

    -- Nothing was reached. Anything this pass moved has to be undone: the
    -- search may have left the map on a continent layer, where
    -- GetCurrentMapZone is 0 and the entire pin layer hides itself -- a far
    -- worse outcome than the lookup simply failing.
    if moved then
        Client.SetMapToCurrentZone()
    end
    return nil, "notListed"
end

-- Parked view ----------------------------------------------------------------
--
-- Moving the world map off the player's own zone is not free, and the cost is
-- structural rather than cosmetic. The minimap pin layer, the HUD waypoint and
-- the rare-alert proximity test all go through GetCurrentZoneView, which needs
-- the OPEN map to be the player's own zone -- GetPlayerMapPosition answers for
-- the viewed map and returns 0, 0 anywhere else, so there is no position left
-- to measure from while the view is elsewhere. Park the view and those three
-- go quiet for exactly as long as it stays parked.
--
-- So a view this addon moved is remembered and handed back. It is released on
-- the first of:
--
--   * the player's own zone changing -- they travelled, which is the whole
--     point of having been shown the other zone;
--   * PARK_SECONDS elapsing, which bounds the outage for a player who read the
--     map and closed it;
--
-- and in both cases only while the view is still exactly where this module
-- left it. A player who worked the zone dropdown themselves has taken the view
-- over and is never overruled -- the parked state is simply dropped.
--
-- Closing the map would be the better release trigger and is NOT available
-- here: this client's fullscreen presentation is recorded leaving
-- WorldMapFrame's shown state true after it closes
-- (docs/WORLD-MAP-PINS-RECOVERY.md, failed approaches), so there is nothing to
-- poll. Recorded as an open question in docs/CLIENT-COMPATIBILITY.md.
local PARK_SECONDS = 45

MapContext.parkedAreaId = nil
MapContext.parkedAt = nil
MapContext.parkedZoneName = nil

local function StandingZoneName()
    local name = Client.GetRealZoneText()
    if type(name) ~= "string" or name == "" then
        name = Client.GetZoneText()
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

function MapContext:ParkView(areaId)
    if type(areaId) ~= "number" then
        return false
    end
    -- A view of the player's OWN zone is not parked: nothing measured from
    -- their position is switched off there, so there is nothing to hand back.
    -- This is the ordinary outcome of revealing a quest while the map happens
    -- to be zoomed out to a continent -- the view moved, but it moved home.
    local _, standingArea = self:GetStandingZone()
    if standingArea == areaId then
        return false
    end
    self.parkedAreaId = areaId
    self.parkedAt = Client.Now()
    self.parkedZoneName = StandingZoneName()
    return true
end

local function ForgetParkedView(self)
    self.parkedAreaId = nil
    self.parkedAt = nil
    self.parkedZoneName = nil
end

-- Puts a parked view back on the player's own zone. `force` skips the two
-- release conditions, for a caller that already knows the player wants their
-- own zone back.
function MapContext:ReleaseParkedView(force)
    if not self.parkedAreaId then
        return false
    end

    if not force then
        -- The player navigated the map themselves, or the client moved it:
        -- the view is no longer this module's to hand back.
        --
        -- Only a view that resolves to a DIFFERENT area counts. nil means the
        -- question could not be answered this tick -- the client's zone list
        -- is documented to come back empty at times -- and reading that as
        -- "the player took over" would abandon the parked view permanently,
        -- leaving the map on another zone with nothing left to hand it back.
        local viewed = self:GetViewedZone()
        if viewed and viewed ~= self.parkedAreaId then
            ForgetParkedView(self)
            return false
        end
        if not viewed then
            return false
        end
        local now = Client.Now()
        local expired = now and self.parkedAt and (now - self.parkedAt) >= PARK_SECONDS
        local name = StandingZoneName()
        local travelled = self.parkedZoneName and name and name ~= self.parkedZoneName
        if not expired and not travelled then
            return false
        end
    end

    ForgetParkedView(self)
    return Client.SetMapToCurrentZone()
end

-- Whether the player is standing in a named sub-area of the zone the map is
-- showing -- in practice, inside a building or a cave.
--
-- There is no direct route to this on this client: IsIndoors and IsOutdoors
-- are both absent, and the minimapZoom/minimapInsideZoom pair that pfQuest
-- uses is measured NOT MAINTAINED here (both read "0" always). What is left is
-- the disagreement between two names the client does give:
--
-- * the zone the MAP is showing, from GetMapZones/GetCurrentMapZone;
-- * the area the player is standing in, from GetZoneText -- which this client
--   answers with the INTERIOR's own name when the player is inside one. That
--   is the same behaviour that once emptied the whole map layer: standing in
--   Brill Town Hall it returns "Brill Town Hall", area 2118, while the map
--   shows Tirisfal Glades, area 85.
--
-- Two samples taken minutes apart at essentially the same spot are what makes
-- this a test rather than a guess: outside at 0.608/0.520, in the village of
-- Brill -- itself a named subzone -- GetZoneText returned "Tirisfal Glades",
-- and inside the town hall at 0.611/0.506 it returned "Brill Town Hall". So it
-- names the zone outdoors even where an outdoor subzone exists, and names the
-- interior only inside one.
--
-- Returns nil, not false, when the comparison cannot be made: without the
-- map-zone route there is only one name and nothing to disagree with.
function MapContext:IsInterior(report)
    report = report or self:Inspect()
    if not report.areaIdFromMapZone or not report.areaIdFromZoneText then
        return nil
    end
    return report.areaIdFromZoneText ~= report.areaIdFromMapZone
end

-- Converts direct database percentages to UV coordinates on the map view the
-- report describes. Child-area and continent transforms remain intentionally
-- unsupported.
function MapContext:DatabaseToCurrentMap(areaId, x, y, report)
    if type(areaId) ~= "number" or type(x) ~= "number" or type(y) ~= "number"
        or x < 0 or x > 100 or y < 0 or y > 100 then
        return nil, "invalidCoordinate"
    end
    local viewedAreaId
    if report then
        -- Stamped by whichever resolver produced the report. Older callers
        -- that hand over a bare Inspect() report keep the previous rule: the
        -- names in it describe the player, so they are only trusted while the
        -- view projects the player.
        viewedAreaId = report.viewedAreaId
        if not viewedAreaId and report.playerX and report.playerY then
            viewedAreaId = report.areaId
        end
    else
        viewedAreaId, report = self:GetViewedZone()
    end
    if viewedAreaId ~= areaId then
        return nil, "differentArea"
    end
    return x / 100, y / 100
end

-- Places a pooled frame on the detected native world-map canvas.
function MapContext:PlaceOnWorldMap(frame, x, y)
    if Client.PositionWorldMapPin(frame, x, y) then
        return true
    end
    return nil, "canvasUnavailable"
end

-- Places a frame at a world position around the minimap. Pending measured
-- evidence: the minimap surface is known to render in a special pass beneath
-- ordinary frames on this client, and no rotation or zoom behaviour has been
-- measured.
function MapContext:PlaceOnMinimap(frame, x, y)
    return nil, "pendingVerification"
end

function MapContext:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    -- One second is deliberately slack: the job returns on its first line
    -- unless a view is actually parked, and the two things it watches for --
    -- the player's zone changing and a 45 second timer -- need no finer
    -- resolution than that.
    driver:Schedule("map.parkedview", 1, function()
        MapContext:ReleaseParkedView()
    end)
end

function MapContext:OnInit()
    UQ:DeclareCapability("mapIdentity", "verified",
        "GetZoneText uniquely joins the current player zone to area ID 12; map-file and player UVs are view-dependent")
    UQ:DeclareCapability("worldMapPins", "verified",
        "production level-120 Button pins confirmed visible in game; first slice is limited to direct current-zone coordinates")
    UQ:DeclareCapability("worldMapAreas", "verified",
        "runtime probes and production confirm 0.5-alpha file-backed tiles, edge-to-edge composition without dark bands, and one numbered marker above each quest area")
    UQ:DeclareCapability("worldMapProbeIsolation", "verified",
        "the completed questarea sequence isolated and persisted each visual property before production rendering was enabled")
    -- The CLIENT capability is measured; the addon feature is not built yet.
    -- Both halves belong in the note, because /uq status prints the state and
    -- "verified" alone would read as "there are pins on your minimap".
    UQ:DeclareCapability("minimapPins", "verified",
        "probe 1.38.0 confirmed in game: children of Minimap render with the world-map contract, the mask does not clip them, and the zoom-0 span is 466.6 yards across a 140px minimap; IsIndoors is absent so the indoor scale cannot be selected; NO pin layer is implemented yet")
    -- Split from minimapPins deliberately. That one says the mouse reaches a
    -- child of Minimap, which the pins' tooltips confirm; this one says a
    -- CLICK on such a child is delivered to the addon rather than kept by the
    -- minimap, and nothing on this client has ever shown that. The layer is
    -- built for it anyway -- the failure mode is a click that does nothing,
    -- and worldMapPinInteraction stood exactly here before its own counters
    -- settled it -- with minimapDiagnostics.pinClicks as the discriminator.
    UQ:DeclareCapability("minimapPinInteraction", "unverified",
        "clicking an addon-owned pin on the minimap follows its quest, the same gesture the world map's pins answer; whether Minimap lets a click reach a child frame is unmeasured here, so minimapDiagnostics.pinClicks counts the clicks that arrive -- zero forever means the minimap keeps them")
    UQ:DeclareCapability("mapZoomLevel", "documented",
        "GetCurrentMapZone is documented to return 0 when no individual zone is selected (continent or world view); used to hide the pin layer on zoom-out since GetPlayerMapPosition alone does not detect it -- the client also projects the player onto a same-continent view")
    UQ:DeclareCapability("worldMapZoneSelection", "documented",
        "SetMapZoom is present at runtime (behavior.json mapwindow/context/globals/SetMapZoom) and the client's API reference documents both forms: one argument selects the continent layer, two select a zone by 1-based index into the list GetMapZones loaded for the SELECTED continent. MapContext:ShowAreas uses it to take the map to a quest's turn-in or objective zone; the index is never assumed, it is read back out of the zone list and the resulting view re-read through GetCurrentMapZone")
    UQ:DeclareCapability("mapColdStartPriming", "verified",
        "probe mapcoldstart 2026-08-23: zoneIndex 0/GetMapInfo nil/player 0,0 immediately after /reload, before the world map was ever shown, is the same signature as a genuine continent view; one Client.SetMapToCurrentZone() call resolved it into zoneIndex 14/mapFile Elwynn/a real player position, so GetCurrentZoneView primes it at most once per session on that exact signature")
end
