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
    if (not report.zoneIndex or report.zoneIndex == 0) and not report.mapFile
        and not self.primeAttempted then
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
    UQ:DeclareCapability("mapZoomLevel", "documented",
        "GetCurrentMapZone is documented to return 0 when no individual zone is selected (continent or world view); used to hide the pin layer on zoom-out since GetPlayerMapPosition alone does not detect it -- the client also projects the player onto a same-continent view")
    UQ:DeclareCapability("mapColdStartPriming", "verified",
        "probe mapcoldstart 2026-08-23: zoneIndex 0/GetMapInfo nil/player 0,0 immediately after /reload, before the world map was ever shown, is the same signature as a genuine continent view; one Client.SetMapToCurrentZone() call resolved it into zoneIndex 14/mapFile Elwynn/a real player position, so GetCurrentZoneView primes it at most once per session on that exact signature")
end
