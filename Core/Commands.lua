--[[
UnrealQuest / Core/Commands.lua

Slash commands are the addon's user surface. Diagnostic commands report what
this build established about the client; tracking commands expose the verified
native quest-watch integration to the player.

The SLASH_ / SlashCmdList registration shape used here is the one already
running on this client in other addons, and the handler takes the argument
string as a direct first argument.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Commands = UQ:NewModule("Commands")

local function Line(text)
    UQ:Print(text)
end

-- string.format's %x wants an integer; the colour helpers return 0..1 floats.
local function Hex(value)
    local scaled = math.floor((value or 0) * 255)
    if scaled < 0 then
        scaled = 0
    elseif scaled > 255 then
        scaled = 255
    end
    return scaled
end

local function StateColor(state)
    if state == "verified" then
        return "|cff55ff55"
    elseif state == "documented" or state == "detected" then
        return "|cffffff55"
    elseif state == "missing" then
        return "|cffff5555"
    end
    return "|cffaaaaaa"
end

local function ShowHelp()
    Line("v" .. UQ.version .. " commands:")
    Line("  /uq config    open the options window")
    Line("  /uq config button on|off      the settings button beside the minimap")
    Line("  /uq status    what this build established about the client")
    Line("  /uq quests    the current quest log model")
    Line("  /uq events    which quest events this client accepted and fired")
    Line("  /uq map       current map identity and world-map pin status")
    Line("  /uq map dots|areas  draw quest objectives as dots or as shaded areas")
    Line("  /uq minimap   quest pins around the player on the minimap")
    Line("  /uq minimap on|off            draw them, or stop")
    Line("  /uq minimap span <yards>       dial in the scale for this zoom step")
    Line("  /uq minimap indoors on|off    withhold markers indoors, or draw them anyway")
    Line("  /uq db        static quest database state")
    Line("  /uq tooltip   entity-tooltip objective diagnostics")
    Line("  /uq tracker   the movable quest tracker window")
    Line("  /uq tracker on|off|toggle     show or hide it")
    Line("  /uq tracker reset             move it back to its default position")
    Line("  /uq tracker objectives all|tracked|none")
    Line("  /uq tracker zones             group by zone, or do not")
    Line("  /uq tracker width <110-600>   how wide the window is")
    Line("  /uq tracker height <60-900>   max height in pixels, 0 for no limit")
    Line("  /uq tracker unfold            reopen every folded quest and zone")
    Line("  /uq tracker unhideall         bring back every quest untracked out of the tracker")
    Line("  /uq tracker native            hide or restore the client's own watch panel")
    if UQ:IsFeatureEnabled("mainQuestWaypoint") then
        Line("  /uq main <index or title>     follow a quest with the HUD waypoint")
        Line("  /uq main                      report the followed quest")
        Line("  /uq main clear                stop following")
        Line("  /uq waypoint  HUD waypoint marker diagnostics")
    else
        Line("  |cff888888/uq main, /uq waypoint   disabled in this build|r")
    end
    Line("  /uq track <index or title>    track a quest")
    Line("  /uq untrack <index or title>  stop tracking a quest")
    Line("  /uq toggle <index or title>   toggle quest tracking")
    Line("  /uq hide <index or title>     hide a quest's pins from the world map")
    Line("  /uq unhide <index or title>   restore a quest's map pins")
    Line("  /uq hidden                    list quests hidden from the map")
    Line("  /uq resetmarked               undo every shift/Ctrl-click 'mark done' on the map")
    Line("  /uq resetmarked all           also undo marks made before that tracking existed")
    Line("  /uq pfquest                   report what pfQuest's saved history holds")
    Line("  /uq pfquest import            import it -- enables pfQuest for one reload if needed")
    Line("  /uq pfquest undo              take back everything a previous import added")
    Line("  /uq marks                 quest marks over creatures in the world")
    Line("  /uq marks on|off          mark quest creatures with a raid target icon")
    Line("  /uq marks icon <1-8>      which mark: 1 star .. 8 skull")
    Line("  /uq marks group on|off    also mark while in a party or raid")
    Line("  /uq worldscan             inventory WorldFrame's children (nameplate hunt)")
    Line("  /uq worldscan <n>         one child in full: every region and child")
    Line("  /uq debug     toggle debug output")
end

local function ShowStatus()
    Line("v" .. UQ.version .. " capability report")
    local index = 1
    local total = table.getn(UQ.capabilityOrder)
    while index <= total do
        local key = UQ.capabilityOrder[index]
        local capability = UQ.capabilities[key]
        Line("  " .. StateColor(capability.state) .. capability.state .. "|r  " .. key
            .. " |cff888888" .. tostring(capability.note) .. "|r")
        index = index + 1
    end

    -- Disabled layers are printed after the capabilities. A layer that
    -- registers nothing looks identical to a layer that is broken unless the
    -- addon says out loud which one it is.
    local featureIndex = 1
    local featureTotal = table.getn(UQ.featureOrder)
    while featureIndex <= featureTotal do
        local key = UQ.featureOrder[featureIndex]
        local feature = UQ.features[key]
        if feature and not feature.enabled then
            Line("  |cffff5555disabled|r  " .. key
                .. " |cff888888" .. tostring(feature.note) .. "|r")
        end
        featureIndex = featureIndex + 1
    end

    local state = UQ:GetModule("QuestState")
    if state then
        local completeness = "complete"
        if not state:IsComplete() then
            completeness = "incomplete, " .. state.collapsedHeaders .. " collapsed header(s)"
        end
        Line("  quest log: " .. state:GetQuestCount() .. " quest(s), snapshot " .. completeness)
    end

    Line("  objective readout path: " .. Client.GetObjectiveMode())
end

local function ShowQuests()
    local state = UQ:GetModule("QuestState")
    if not state then
        Line("quest state module is not loaded")
        return
    end
    local quests = state:GetOrderedQuests()
    local total = table.getn(quests)
    if total == 0 then
        Line("no quests in the log")
        return
    end
    if not state:IsComplete() then
        Line("|cffffff55snapshot is incomplete: " .. state.collapsedHeaders
            .. " collapsed header(s) hide their quests from the client|r")
    end
    -- Non-zero means something between the client and this addon is prefixing
    -- levels onto quest titles. The titles below are the stripped ones, so the
    -- count is the only place that shows it happened at all.
    local decorated = Client.GetQuestTitleDecorationCount and Client.GetQuestTitleDecorationCount()
    if decorated and decorated > 0 then
        Line("|cff888888" .. decorated .. " title read(s) arrived carrying a level prefix; "
            .. "stripped before matching|r")
    end

    local index = 1
    while index <= total do
        local quest = quests[index]
        local r, g, b = Client.GetQuestLevelColor(quest.level)
        local identity
        if quest.questId then
            identity = "db " .. quest.questId .. " (" .. tostring(quest.matchConfidence) .. ")"
        else
            identity = "db " .. tostring(quest.matchConfidence)
        end
        local complete = ""
        if quest.isComplete == 1 then
            complete = " |cff55ff55complete|r"
        elseif quest.isComplete == -1 then
            complete = " |cffff5555failed|r"
        end
        local tracked = ""
        local tracker = UQ:GetModule("Tracker")
        if tracker and tracker:IsTracked(quest) then
            tracked = " |cff" .. UQ.colors.accentHex .. "tracked|r"
        end

        Line(string.format("  [%d] %s(%s)|r %s |cff888888%s|r%s%s",
            quest.index,
            string.format("|cff%02x%02x%02x", Hex(r), Hex(g), Hex(b)),
            tostring(quest.level),
            tostring(quest.title),
            identity,
            complete,
            tracked))

        local objectiveIndex = 1
        local objectiveTotal = 0
        if quest.objectives then
            objectiveTotal = quest.objectiveCount or 0
        end
        while objectiveIndex <= objectiveTotal do
            local objective = quest.objectives[objectiveIndex]
            if objective and objective.text then
                local mark = "-"
                if objective.finished then
                    mark = "|cff55ff55x|r"
                end
                Line("      " .. mark .. " " .. objective.text)
            end
            objectiveIndex = objectiveIndex + 1
        end
        index = index + 1
    end
end

local function ShowEvents()
    local events = UQ:GetModule("Events")
    if not events then
        Line("event module is not loaded")
        return
    end
    Line("event registration on this client:")
    local report = events:GetRegistrationReport()
    local index = 1
    local total = table.getn(report)
    while index <= total do
        local entry = report[index]
        local mark
        if entry.accepted then
            mark = "|cff55ff55accepted|r"
        else
            mark = "|cffff5555rejected|r"
        end
        Line("  " .. mark .. "  " .. entry.event .. "  fired " .. entry.observed .. "x this session")
        index = index + 1
    end
    Line("|cff888888counts persist across sessions; report them to close the quest-event gap|r")
end

local function ShowMap(target)
    local map = UQ:GetModule("MapContext")
    if not map then
        Line("map module is not loaded")
        return
    end

    -- The same switch as the options page's "Show quest objectives as dots".
    -- Writing the setting is all this has to do: WorldMapPins carries it in
    -- its view signature and repaints on the next refresh.
    target = string.lower(UQ.Trim(target) or "")
    if target == "dots" or target == "areas" then
        local config = UQ:GetModule("Config")
        if not config then
            Line("config module is not loaded")
            return
        end
        config:Set("mapObjectiveDots", target == "dots")
        Line("world-map quest objectives drawn as " .. target)
        return
    end
    local report = map:Inspect()
    Line("map observation and current-zone pin status:")
    Line("  GetMapInfo file:      " .. tostring(report.mapFile))
    Line("  tile height/width:    " .. tostring(report.tileHeight) .. " / " .. tostring(report.tileWidth))
    Line("  continent / zone idx: " .. tostring(report.continent) .. " / " .. tostring(report.zoneIndex))
    Line("  GetZoneText:          " .. tostring(report.zoneText))
    Line("  GetSubZoneText:       " .. tostring(report.subZoneText))
    Line("  player map position:  " .. tostring(report.playerX) .. ", " .. tostring(report.playerY))
    Line("  area id from map file: " .. tostring(report.areaIdFromMapFile)
        .. " (" .. tostring(report.areaIdFromMapFileHow) .. ")")
    Line("  area id from zone text: " .. tostring(report.areaIdFromZoneText)
        .. " (" .. tostring(report.areaIdFromZoneTextHow) .. ")")
    Line("  area id from real zone text: " .. tostring(report.areaIdFromRealZoneText)
        .. " (" .. tostring(report.areaIdFromRealZoneTextHow) .. ")")
    Line("  map zone name: " .. tostring(report.mapZoneName))
    Line("  area id from map zone: " .. tostring(report.areaIdFromMapZone)
        .. " (" .. tostring(report.areaIdFromMapZoneHow) .. ")")
    Line("  area id used: " .. tostring(report.areaId)
        .. " (" .. tostring(report.areaIdHow) .. ")")
    local pins = UQ:GetModule("WorldMapPins")
    if pins then
        local status = pins:GetStatus()
        if not status.renderEnabled then
            Line("  map overlay:         disabled")
        elseif status.markersEnabled then
            Line("  quest markers:       " .. tostring(status.visible)
                .. " visible / " .. tostring(status.pooled) .. " pooled")
        else
            Line("  quest markers:       retired; hover an area for the quest")
        end
        -- Read next to itemUseUnknown below: "unreadable" there plus "unknown"
        -- here is a dead container API; "unreadable" there with the bags
        -- reporting items is a data or matching problem instead.
        local bags = UQ:GetModule("BagItems")
        local bagStatus = bags and bags:GetStatus()
        local bagLine = nil
        if bagStatus then
            if bagStatus.available then
                bagLine = tostring(bagStatus.distinctItems) .. " distinct items"
            else
                bagLine = "unreadable"
            end
        end
        if status.renderEnabled and status.areasEnabled then
            Line("  objective style:     " .. (status.objectiveDots and "dots" or "areas")
                .. " (/uq map dots|areas)")
            Line("  objective frames:    " .. tostring(status.areaVisible)
                .. " visible / " .. tostring(status.areaPooled) .. " pooled")
            Line("  map colours:          blue objectives / green turn-ins / gold patrols"
                .. (status.markersEnabled and " + yellow numbered markers" or ""))
            -- Marker counts, read together with the hover counters below: a
            -- non-zero count with nothing on screen means the client's gossip
            -- icon file did not resolve, which is the one unverified thing
            -- about both pools.
            Line("  giver \"!\" markers:   " .. tostring(status.giverVisible)
                .. " visible / " .. tostring(status.giverPooled) .. " pooled")
            -- Invisible by construction (Map/WorldMapPins.lua): this is the
            -- route's hit test, not something the player can see. A zero here
            -- with a drawn route means the path is unhoverable.
            Line("  patrol hover targets: " .. tostring(status.patrolVisible)
                .. " visible / " .. tostring(status.patrolPooled) .. " pooled")
            -- A width above the floor means the pool bound widened the spacing
            -- and the stamps were grown to keep the stroke continuous. Read it
            -- when a route looks heavier than it should.
            Line("  patrol line stamps:  " .. tostring(status.patrolStrokes)
                .. " visible at " .. tostring(status.patrolStrokeWidth) .. "px")
            Line("  turn-in \"?\" markers: " .. tostring(status.turnInVisible)
                .. " visible / " .. tostring(status.turnInPooled) .. " pooled"
                .. (status.inProgressTurnIns and "" or " (ready-to-hand-in only)"))
            -- Item-use objective targets left off the map because the bags
            -- could not be read, not because the item is missing. This is the
            -- answer to "I am carrying the quest item and its target still is
            -- not shown": non-zero blames the container API, and /uq status
            -- will show bagScan alongside it.
            Line("  item-use unresolved: " .. tostring(status.itemUseUnknown)
                .. (bagLine and (" (bags: " .. bagLine .. ")") or ""))
            -- Zero here after a session spent hovering areas is the symptom of
            -- the recorded "custom map child receives no mouse" failure, not of
            -- an empty quest log.
            Line("  area hovers seen:    " .. tostring(status.areaHovers))
            -- Zero here after shift-clicking a "!" is the symptom of the open
            -- worldMapPinInteraction question, not of QuestHistory failing to
            -- mark the quest done -- OnClick may simply never have reached
            -- this smaller pin at all.
            Line("  giver hovers/clicks: " .. tostring(status.giverHovers)
                .. " / " .. tostring(status.giverClicks))
            -- The "?" pins take no clicks, so hovers are all they can report.
            -- Read against area hovers: the turn-in pin usually sits on top of
            -- a green area tile, so zero here with area hovers rising means
            -- the tile is still winning the mouse.
            Line("  turn-in hovers:      " .. tostring(status.turnInHovers))
            -- Rising after a shift-click means the overlay did rebuild, so a
            -- marker still on screen is a stale fullscreen-map paint rather
            -- than a stale quest layer.
            Line("  overlay rebuilds:    " .. tostring(status.rebuilds))
        elseif status.renderEnabled then
            Line("  quest areas:         unavailable")
            Line("  marker colours:      yellow objectives / green turn-ins")
        end
    end
end

local function ShowMinimap(target)
    target = string.lower(UQ.Trim(target) or "")
    local pins = UQ:GetModule("MinimapPins")
    local config = UQ:GetModule("Config")
    if not pins or not config then
        Line("minimap pin module is not loaded")
        return
    end

    if target == "on" or target == "off" then
        config:Set("minimapPins", target == "on")
        pins.dirty = true
        pins:Refresh()
        Line("minimap quest pins " .. target)
        return
    end

    -- "/uq minimap span <yards>" or "/uq minimap span reset". The scale of the
    -- minimap cannot be read back from Lua on this client -- nothing on it is
    -- a reference this addon did not draw itself -- so the only instrument is
    -- a player walking past a pin and seeing whether it stays put. Too large a
    -- span makes every offset undershoot and the pin creeps along in the
    -- direction of travel; too small and it slides the other way.
    if target == "indoors on" or target == "indoors off" then
        config:Set("minimapPinsHideIndoors", target == "indoors on")
        pins.dirty = true
        pins:Refresh()
        if target == "indoors on" then
            Line("minimap markers are withheld indoors")
        else
            Line("minimap markers are drawn indoors, at a scale this client cannot confirm")
        end
        return
    end

    local spanWord, spanValue = string.find(target, "^span")
    if spanWord then
        local argument = UQ.Trim(string.sub(target, spanValue + 1)) or ""
        local yards = tonumber(argument)
        if argument == "" then
            local status = pins:GetStatus()
            Line("minimap scale at zoom " .. tostring(status.zoom) .. ": "
                .. tostring(status.span) .. " yards across (" .. tostring(status.spanEvidence) .. ")")
            Line("  /uq minimap span <yards>   set the scale for this zoom step, here")
            Line("  /uq minimap span reset     go back to the built-in constant")
            Line("  |cff888888a marker that creeps WITH you means the number is too big|r")
            return
        end
        if argument == "reset" then
            yards = nil
        elseif not yards or yards <= 0 then
            Line("give a number of yards, or 'reset'")
            return
        end
        local key, zoom, indoor, span, evidence = pins:SetSpanOverride(yards)
        if not key then
            Line("the minimap zoom could not be read, so there is nothing to key this to")
            return
        end
        Line("minimap scale at zoom " .. tostring(zoom)
            .. " (" .. tostring(indoor or "environment unknown") .. "): "
            .. tostring(span) .. " yards across (" .. tostring(evidence) .. ")")
        return
    end

    local status = pins:GetStatus()
    Line("minimap quest pins:")
    Line("  setting:        " .. (config:Get("minimapPins") and "on" or "off"))
    Line("  state:          " .. tostring(status.state))
    Line("  drawn:          " .. tostring(status.objectives) .. " objectives, "
        .. tostring(status.givers) .. " givers, " .. tostring(status.turnIns) .. " turn-ins")
    Line("  clamped to edge: " .. tostring(status.clamped) .. " of " .. tostring(status.targets))
    Line("  minimap width:  " .. tostring(status.width) .. "px at zoom " .. tostring(status.zoom))
    Line("  scale:          " .. tostring(status.span) .. " yards across ("
        .. tostring(status.spanEvidence) .. ")")
    if status.spanEvidence ~= "measured" then
        Line("  |cffffcc00only zoom 0 is measured on this client; other steps use Vanilla constants|r")
    end
    if status.rotating then
        Line("  |cffff5555rotateMinimap is on: pins are hidden, this client exposes no player facing|r")
    end
    if status.spanEvidence ~= "playerCalibrated" then
        Line("  |cff888888/uq minimap span <yards> dials this in where it is wrong|r")
    end
    if config:Get("minimapPinsHideIndoors") ~= false then
        Line("  indoors:        markers withheld (the scale inside cannot be established here)")
    else
        Line("  indoors:        markers drawn at the outdoor scale")
    end
    if status.pinFailures and status.pinFailures > 0 then
        Line("  pin failures:   " .. tostring(status.pinFailures))
    end
end

local function ShowDatabase()
    local database = UQ:GetModule("Database")
    if not database then
        Line("database module is not loaded")
        return
    end
    Line("world data: " .. database:GetStatus())
    if database.available then
        Line("  titles indexed: " .. database.indexedCount)
        local matcher = UQ:GetModule("QuestMatch")
        if matcher then
            Line("  unmatched titles recorded: " .. matcher:GetUnmatchedCount())
        end
    else
        Line("  |cffff5555the bundled world data did not load; check the addon install|r")
    end
end

local function ShowTooltip()
    local tooltip = UQ:GetModule("EntityTooltip")
    if not tooltip then
        Line("entity tooltip module is not loaded")
        return
    end
    local status = tooltip:GetStatus()
    Line("entity-tooltip objective diagnostics:")
    -- See Tooltip/EntityTooltip.lua's diagnostics comment block for how to
    -- read these together -- they split the pipeline into stages so a silent
    -- failure can be narrowed down without a screenshot.
    Line("  Refresh() calls seen:         " .. tostring(status.refreshCount))
    if not status.refreshCount or status.refreshCount == 0 then
        Line("  |cffff5555Refresh has never run -- the poll job or OnShow hook never fired|r")
    end
    Line("  objective formats resolved:   " .. tostring(status.patternsResolved)
        .. " / " .. tostring(status.patternsExpected))
    if status.patternsResolved == 0 then
        Line("  |cffff5555no QUEST_MONSTERS_KILLED-style format string resolved; objective lines cannot be"
            .. " split into a name and counters|r")
    end
    Line("  creature names read:          " .. tostring(status.labelReads))
    Line("  last tooltip text read:       " .. tostring(status.lastSeenLabel or "<none>"))
    if status.refreshCount and status.refreshCount > 0 and status.labelReads == 0 then
        Line("  |cffff5555Refresh ran but GameTooltipTextLeft1 never returned text -- identity, not matching|r")
    end
    Line("  quest-linked mouseovers seen: " .. tostring(status.matches)
        .. " (" .. tostring(status.directMatches) .. " from the log line, "
        .. tostring(status.databaseMatches) .. " from world data)")
    if status.labelReads > 0 and status.matches == 0 then
        Line("  |cffff5555creature names were read but never matched a quest objective|r")
    end
    Line("  append failures:              " .. tostring(status.appendFailures))
    if status.matches > 0 and status.appendFailures >= status.matches then
        Line("  |cffff5555every match failed to append -- GameTooltip resolution or IsShown gating is the problem|r")
    end
    Line("  currently hovered unit key:   " .. tostring(status.currentUnit))
end

local function ShowMarks(target)
    local marks = UQ:GetModule("QuestMarks")
    if not marks then
        Line("quest mark module is not loaded")
        return
    end
    local config = UQ:GetModule("Config")

    if target == "on" or target == "off" then
        if config then
            config:Set("questMarks", target == "on")
        end
        if target == "off" then
            marks:ClearReachable()
            Line("quest marks off. Only a marked creature you can still name -- your target or"
                .. " what you are hovering -- could be cleared; the rest keep their mark until"
                .. " you look at them again")
        else
            marks.refused = false
            marks.stats.unconfirmed = 0
            Line("quest marks on")
        end
        return
    end

    -- No "^" anchor: gfind does not honour one, which silently matches nothing.
    local subCommand, rest = "", ""
    for foundCommand, foundRest in string.gfind(target, "(%S+)%s*(.*)") do
        subCommand = string.lower(foundCommand)
        rest = foundRest
    end

    if subCommand == "icon" then
        local index = tonumber(UQ.Trim(rest) or "")
        if not index or index < 1 or index > 8 then
            Line("|cffff5555icon takes 1-8: 1 star, 2 circle, 3 diamond, 4 triangle, 5 moon,"
                .. " 6 square, 7 cross, 8 skull|r")
            return
        end
        if config then
            config:Set("questMarkIndex", index)
        end
        Line("quest creatures will be marked with the " .. marks:MarkName(index))
        return
    end

    if subCommand == "group" then
        local mode = string.lower(UQ.Trim(rest) or "")
        if mode ~= "on" and mode ~= "off" then
            Line("|cffff5555group takes on or off|r")
            return
        end
        if config then
            config:Set("questMarksInGroup", mode == "on")
        end
        if mode == "on" then
            Line("|cffffff55quest creatures may be marked while grouped. The server rejected the solo"
                .. " case; group leader or raid assistant remains the only unverified route. Everyone"
                .. " sees these marks and they overwrite whatever your group had set|r")
        else
            Line("group quest marks off; solo marks are unavailable on this realm")
        end
        return
    end

    local status = marks:GetStatus()
    Line("quest marks over creatures:")
    if not status.available then
        Line("  |cffff5555SetRaidTarget/GetRaidTargetIndex are not callable here; nothing can be"
            .. " drawn over a creature on this client at all|r")
        return
    end
    Line("  enabled:                 " .. (status.enabled and "yes" or "no")
        .. "   |cff888888/uq marks on|off|r")
    Line("  mark used:               " .. marks:MarkName(status.objectiveIndex)
        .. " for objectives, " .. marks:MarkName(status.turnInIndex) .. " for turn-ins"
        .. "   |cff888888/uq marks icon 1-8|r")
    Line("  in a group:              " .. (status.inGroup and "yes" or "no")
        .. (status.allowedHere and "" or (status.inGroup
            and "  |cffffff55-- paused; /uq marks group on|r"
            or "  |cffff5555-- unavailable: this realm ignored every solo write|r")))
    Line("  marks written:           " .. tostring(status.writes)
        .. ", confirmed " .. tostring(status.confirmed)
        .. ", cleared " .. tostring(status.cleared))
    Line("  last marked:             " .. tostring(status.lastMarked or "<none>")
        .. " |cff888888" .. tostring(status.lastKind or "") .. "|r")

    -- The one thing GetRaidTargetIndex alone cannot tell you, said out loud:
    -- the write is a server round trip, so "no confirmation yet" and "the
    -- server refused it" look identical for the first few seconds.
    if not status.inGroup then
        Line("  |cffff5555no persistent 3D quest marker is available while solo. The only remaining"
            .. " test is as party leader or raid assistant: /uq marks group on|r")
    elseif status.refused then
        Line("  |cffff5555the server never confirmed a single mark, so it is refusing them --"
            .. " this group role may not be allowed to mark. Stopped trying for this session;"
            .. " /uq marks on retries|r")
    elseif status.writes > 0 and status.confirmed == 0 then
        Line("  |cffffff55written but not confirmed yet. SetRaidTarget sends the value to the"
            .. " server, so a mark takes a round trip to read back -- give it a few seconds|r")
    elseif status.confirmed > 0 then
        Line("  |cff888888the server accepts these marks. Hover or target a quest creature and it"
            .. " gets one|r")
    end
end

local function ShowWorldScan(target)
    local scan = UQ:GetModule("WorldFrameScan")
    if not scan then
        Line("world scan module is not loaded")
        return
    end

    local childIndex = tonumber(target)
    if childIndex then
        local detail = scan:Detail(childIndex)
        if not detail then
            Line("no WorldFrame child at index " .. tostring(childIndex))
            return
        end
        local index = 1
        local total = table.getn(detail)
        while index <= total do
            Line(detail[index])
            index = index + 1
        end
        return
    end

    local ok, reason = scan:Scan()
    if not ok then
        Line("|cffff5555" .. tostring(reason) .. "|r")
        return
    end
    -- A summary only. The first version of this printed all 26 lines and the
    -- client crashed twice on it -- the walk itself completed and the dump was
    -- written both times, so what could not survive was the chat flood, not the
    -- inspection. The list is written to SavedVariables and read from there.
    Line("WorldFrame has " .. tostring(scan.childCount) .. " children; "
        .. tostring(table.getn(scan.lines)) .. " inventoried.")
    Line("|cff888888saved to UnrealQuestDB.worldFrameScan -- /reload to flush it to disk, then read"
        .. " the file. Deliberately not printed here: 26 lines of it crashed this client|r")
end

-- Resolves a command target against the live model, never the raw quest log.
-- Raw indexes include headers, while the model contains quests only; matching
-- through it keeps a header from ever being passed to the watch APIs.
local function FindQuest(target)
    local state = UQ:GetModule("QuestState")
    if not state then
        Line("quest state module is not loaded")
        return nil
    end

    target = UQ.Trim(target)
    if not target or target == "" then
        Line("usage: /uq track <index or title fragment>")
        return nil
    end

    local index = tonumber(target)
    local quests = state:GetOrderedQuests()
    local questIndex = 1
    local total = table.getn(quests)
    if index and tostring(index) == target then
        while questIndex <= total do
            local quest = quests[questIndex]
            if quest.index == index then
                return quest
            end
            questIndex = questIndex + 1
        end
        Line("no quest at log index " .. target .. "; use /uq quests to see available quests")
        return nil
    end

    local targetKey = UQ.NameKey(target)
    if not targetKey then
        Line("enter a quest index or title fragment")
        return nil
    end

    local matches = {}
    while questIndex <= total do
        local quest = quests[questIndex]
        if string.find(quest.titleKey, targetKey, 1, true) then
            table.insert(matches, quest)
        end
        questIndex = questIndex + 1
    end

    local matchCount = table.getn(matches)
    if matchCount == 1 then
        return matches[1]
    end
    if matchCount == 0 then
        Line("no quest title matches '" .. target .. "'; use /uq quests to see available quests")
        return nil
    end

    Line("'" .. target .. "' matches several quests; use its index:")
    questIndex = 1
    while questIndex <= matchCount do
        local quest = matches[questIndex]
        Line("  [" .. quest.index .. "] " .. quest.title)
        questIndex = questIndex + 1
    end
    return nil
end

local function ChangeTracking(target, action)
    local tracker = UQ:GetModule("Tracker")
    if not tracker then
        Line("tracker module is not loaded")
        return
    end

    local quest = FindQuest(target)
    if not quest then
        return
    end

    local wasTracked = tracker:IsTracked(quest)
    local changed = false
    if action == "track" then
        if wasTracked then
            Line("already tracking '" .. quest.title .. "'")
            return
        end
        changed = tracker:Track(quest)
    elseif action == "untrack" then
        if not wasTracked then
            Line("'" .. quest.title .. "' is not tracked")
            return
        end
        changed = tracker:Untrack(quest)
    else
        changed = tracker:Toggle(quest)
    end

    if not changed then
        Line("UnrealQuest did not update tracking for '" .. quest.title .. "'")
        return
    end
    if tracker:IsTracked(quest) then
        Line("tracking '" .. quest.title .. "'")
    else
        Line("stopped tracking '" .. quest.title .. "'")
    end
end

-- Map pin visibility -----------------------------------------------------------

-- WorldMapPins caches its layout by view signature and only rebuilds when
-- that signature changes or self.dirty is set (see its OnEnable listener).
-- Toggling a hide entry changes neither the view nor the quest log, so the
-- next redraw has to be forced by hand or the pin would linger until
-- something else marks the pool dirty.
-- Both map layers draw the same scene, so anything that changes what belongs
-- on it -- hiding a quest, marking one done -- has to reach both.
local function MarkMapDirty()
    local pins = UQ:GetModule("WorldMapPins")
    if pins then
        pins.dirty = true
    end
    local minimap = UQ:GetModule("MinimapPins")
    if minimap then
        minimap.dirty = true
    end
end

local function ChangeMapVisibility(target, hide)
    local config = UQ:GetModule("Config")
    if not config then
        Line("config module is not loaded")
        return
    end

    local quest = FindQuest(target)
    if not quest then
        return
    end
    if type(quest.questId) ~= "number" then
        Line("'" .. tostring(quest.title) .. "' has no resolved quest id to hide")
        return
    end

    -- Stored as an explicit boolean override rather than deleted on unhide:
    -- some quests (see WorldMapPins.DEFAULT_HIDDEN_QUEST_IDS, e.g. CLUCK!) are
    -- hidden by default for every player, so "unhide" has to be able to force
    -- one back on rather than merely clearing an override that was never set.
    if config:SetSectionEntry("hiddenMapQuests", quest.questId, hide) then
        if hide then
            Line("hiding map pins for '" .. tostring(quest.title) .. "'")
        else
            Line("restored map pins for '" .. tostring(quest.title) .. "'")
        end
        MarkMapDirty()
    else
        Line("could not persist that change for '" .. tostring(quest.title) .. "'")
    end
end

local function ShowHiddenQuests()
    local config = UQ:GetModule("Config")
    local pins = UQ:GetModule("WorldMapPins")
    local database = UQ:GetModule("Database")
    if not config or not pins then
        Line("required modules are not loaded")
        return
    end

    local section = config:GetSection("hiddenMapQuests")
    local defaults = pins:GetDefaultHiddenQuestIds()
    local any = false
    local questId

    for questId in pairs(defaults) do
        if pins:IsQuestHidden(questId, config) then
            if not any then
                Line("quests hidden from the map:")
                any = true
            end
            local title = database and database:GetQuestTitle(questId)
            Line("  " .. tostring(questId) .. "  " .. tostring(title or "?") .. " |cff888888(default)|r")
        end
    end

    for questId, override in pairs(section) do
        if override == true and defaults[questId] == nil then
            if not any then
                Line("quests hidden from the map:")
                any = true
            end
            local title = database and database:GetQuestTitle(questId)
            Line("  " .. tostring(questId) .. "  " .. tostring(title or "?"))
        end
    end

    if not any then
        Line("no quests are hidden from the map")
    end
end

-- Undoes WorldMapPins' shift-click and Ctrl+click "mark done" gestures --
-- QuestHistory:ResetManual() only touches quests recorded through those, so a
-- quest this addon marked done itself by watching it leave the log complete
-- is left alone. "/uq resetmarked all" instead clears every marked-done
-- quest without that distinction -- the fallback for a quest marked before
-- the manual-tracking split existed to record it, which ResetManual alone
-- can never find (see QuestHistory:GetDoneCount's comment).
local function ResetMarkedQuests(target)
    local questHistory = UQ:GetModule("QuestHistory")
    if not questHistory then
        Line("quest history module is not loaded")
        return
    end

    local all = string.lower(UQ.Trim(target) or "") == "all"
    local reset
    if all then
        reset = questHistory:ResetAll()
    else
        reset = questHistory:ResetManual()
    end
    local total = table.getn(reset)

    if total == 0 then
        if not all and questHistory:GetDoneCount() > 0 then
            Line("no quests were marked done through shift/Ctrl-click since this tracking was added")
            Line("  there are marked-done quests recorded from before that -- /uq resetmarked all clears those too")
        else
            Line("no marked-done quests to reset")
        end
        return
    end

    local database = UQ:GetModule("Database")
    Line("reset " .. total .. " quest(s) marked done"
        .. (all and "" or " by hand") .. ":")
    local index = 1
    while index <= total do
        local questId = reset[index]
        local title = database and database:GetQuestTitle(questId)
        Line("  " .. tostring(questId) .. "  " .. tostring(title or "?"))
        index = index + 1
    end
    MarkMapDirty()
end

-- pfQuest history import ---------------------------------------------------------
--
-- The same three actions the options page offers, for a player who would
-- rather not open a window -- and the only place the per-quest detail of an
-- import is ever printed. Quest/PfQuestImport.lua does the work; this only
-- reports it.

local function ImportPfQuestHistory(argument)
    local importer = UQ:GetModule("PfQuestImport")
    if not importer then
        Line("the pfQuest import module is not loaded")
        return
    end

    local action = string.lower(UQ.Trim(argument) or "")

    if action == "undo" then
        local total = importer:Undo()
        if total == 0 then
            Line("no quests were imported from pfQuest, so there is nothing to take back")
        else
            Line("took back " .. total .. " quest(s) imported from pfQuest")
            Line("  quests marked done by this addon itself, or by hand, were left alone")
        end
        return
    end

    if action ~= "" and action ~= "import" then
        Line("unknown option: " .. action .. " -- use /uq pfquest, /uq pfquest import or /uq pfquest undo")
        return
    end

    if action == "" then
        Line(importer:Describe())
        local state = importer:GetState().state
        if state == "ready" then
            Line("  /uq pfquest import marks those quests done here")
        elseif state == "disabled" or state == "unavailable" then
            Line("  /uq pfquest import switches pfQuest on for one reload, imports, and")
            Line("  switches it back off -- this client will not let an addon reload for you")
        elseif state == "pending" then
            Line("  type /reload -- the import is waiting for it")
        end
        return
    end

    -- Exactly what the options-page button does, including the enable-and-ask
    -- path when pfQuest is installed but switched off. PfQuestImport:Press
    -- prints the headline; the detail below is what the command adds over the
    -- button.
    local before = importer:GetState().state
    importer:Press()
    if before ~= "ready" then
        return
    end

    local report = importer:Scan()
    if report.alreadyDone > 0 then
        Line("  " .. report.alreadyDone .. " were already recorded here and were left as they were")
    end
    local skipped = report.unknown + report.unmatched + report.ambiguous
    if skipped > 0 then
        Line("  " .. skipped .. " skipped: not in this client's quest data, or a title matching"
            .. " more than one quest")
    end
    if report.waiting > 0 then
        Line("  " .. report.waiting .. " could not be resolved yet -- the quest title index is"
            .. " still building; run this again in a moment")
    end
    Line("  /uq pfquest undo takes back everything an import added")
end

-- Quest tracker window -----------------------------------------------------------

local function ShowTracker(argument)
    local tracker = UQ:GetModule("TrackerFrame")
    local config = UQ:GetModule("Config")
    if not tracker or not config then
        Line("the tracker module is not loaded")
        return
    end

    local command = ""
    local value = ""
    for foundCommand, foundValue in string.gfind(argument or "", "(%S+)%s*(.*)") do
        command = string.lower(foundCommand)
        value = UQ.Trim(foundValue) or ""
    end

    if command == "on" or command == "show" then
        tracker:SetShown(true)
        Line("quest tracker shown")
        return
    elseif command == "off" or command == "hide" then
        tracker:SetShown(false)
        Line("quest tracker hidden")
        return
    elseif command == "toggle" then
        tracker:SetShown(not tracker:IsShown())
        Line("quest tracker " .. (tracker:IsShown() and "shown" or "hidden"))
        return
    elseif command == "reset" then
        tracker:ResetPosition()
        tracker.dirty = true
        tracker:Refresh()
        Line("quest tracker moved back to its default position")
        return
    elseif command == "objectives" then
        local mode = string.lower(value)
        if mode ~= "all" and mode ~= "tracked" and mode ~= "none" then
            Line("usage: /uq tracker objectives all|tracked|none")
            return
        end
        config:Set("trackerShowObjectives", mode)
        tracker.dirty = true
        tracker:Refresh()
        Line("tracker objectives: " .. mode)
        return
    elseif command == "zones" then
        local grouped = not (config:Get("trackerGroupByZone") and true or false)
        config:Set("trackerGroupByZone", grouped)
        tracker.dirty = true
        tracker:Refresh()
        Line("tracker zone headers " .. (grouped and "on" or "off"))
        return
    elseif command == "native" then
        local hide = not (config:Get("trackerHideNativeWatch") and true or false)
        config:Set("trackerHideNativeWatch", hide)
        tracker:ApplyNativeWatchVisibility()
        Line("native quest watch panel " .. (hide and "hidden" or "shown"))
        if hide then
            Line("  |cff888888the client re-shows it on its own, so it is hidden again on a timer|r")
        end
        return
    elseif command == "width" then
        local width = tonumber(value)
        if not width or width < 110 or width > 600 then
            Line("usage: /uq tracker width <110-600>")
            return
        end
        config:Set("trackerWidth", width)
        tracker.dirty = true
        tracker:Refresh()
        Line("tracker width: " .. width)
        return
    elseif command == "height" then
        local height = tonumber(value)
        if not height or (height ~= 0 and (height < 60 or height > 900)) then
            Line("usage: /uq tracker height <60-900>, or 0 for no limit")
            return
        end
        config:Set("trackerHeight", height)
        tracker.dirty = true
        tracker:Refresh()
        if height == 0 then
            Line("tracker max height: none (grows with the log)")
        else
            Line("tracker max height: " .. height .. "px")
        end
        return
    elseif command == "unfold" then
        config:ClearSection("trackerCollapsedQuests")
        config:ClearSection("trackerCollapsedZones")
        config:Set("trackerCollapsed", false)
        tracker.dirty = true
        tracker:Refresh()
        Line("every folded quest and zone reopened")
        return
    elseif command == "unhideall" then
        config:ClearSection("trackerHiddenQuests")
        tracker.dirty = true
        tracker:Refresh()
        Line("every quest untracked out of the tracker is back")
        return
    elseif command ~= "" then
        Line("unknown tracker command: " .. command)
    end

    local report = tracker:GetReport()
    Line("quest tracker window")
    if not report.created then
        Line("  |cffff5555the window could not be created on this client|r")
        return
    end
    Line("  " .. (report.enabled and "shown" or "hidden")
        .. (report.collapsed and ", folded to the title bar" or "")
        .. " -- " .. tostring(report.lines) .. " rows")
    local height = report.height
    if type(height) ~= "number" or height <= 0 then
        height = "auto"
    else
        height = string.format("%.0f", height) .. " max"
    end
    Line("  width=" .. tostring(report.width) .. " height=" .. tostring(height)
        .. " objectives=" .. tostring(report.objectives)
        .. " zones=" .. (report.groupByZone and "on" or "off"))
    Line("  position " .. tostring(report.point) .. " "
        .. string.format("%.0f, %.0f", report.x or 0, report.y or 0)
        .. " (UIParent) -- drags=" .. tostring(report.drags)
        .. " failures=" .. tostring(report.dragFailures)
        .. " resizes=" .. tostring(report.resizes))
    Line("  redraws=" .. tostring(report.redraws) .. " row clicks=" .. tostring(report.clicks))
    Line("  native watch panel " .. (report.hideNativeWatch and "hidden" or "shown"))
    if report.dragFailures > 0 then
        Line("  |cffff5555StartMoving was refused -- see docs/QUEST-TRACKER.md|r")
    end
end

-- Main quest -----------------------------------------------------------------

-- Both /uq main and /uq waypoint drive the gated layer. When the gate is off
-- their modules still exist and still answer, but they have registered nothing,
-- so every counter reads zero and every report reads like a broken feature.
-- Say what is actually happening instead.
local function FeatureDisabledNotice()
    Line("the main quest + HUD waypoint layer is |cffff5555disabled|r in this build")
    Line("  the code is still in the addon, but it registers nothing: no driver")
    Line("  jobs, no click chains on the quest log, no marker frame.")
    Line("  why: this client has no readable player facing and no camera getter,")
    Line("  so the marker cannot be made accurate. See docs/HUD-WAYPOINT.md.")
    Line("  to re-enable: UQ:DeclareFeature(\"mainQuestWaypoint\", true, ...) in")
    Line("  Core/Namespace.lua, then /reload.")
end

local function ShowMainQuest()
    local mainQuest = UQ:GetModule("MainQuest")
    local clicks = UQ:GetModule("QuestClicks")
    if not mainQuest then
        Line("the main quest module is unavailable")
        return
    end

    local report = mainQuest:GetReport()
    if not report.titleKey then
        Line("not following any quest")
        Line("  click a quest in the quest log or the tracker, or /uq main <index or title>")
    else
        Line("following: |cff" .. UQ.colors.accentHex
            .. tostring(report.title or report.titleKey) .. "|r")
        if report.title then
            Line("  quest log index " .. tostring(report.index)
                .. ", level " .. tostring(report.level)
                .. ", match " .. tostring(report.matchConfidence))
            if report.isComplete == 1 then
                Line("  ready to hand in; the waypoint points at the turn-in")
            end
        else
            Line("  |cffff5555not currently in the quest log|r (remembered as '"
                .. tostring(report.titleKey) .. "')")
        end
    end
    Line("  restored=" .. tostring(report.restored)
        .. " selections=" .. tostring(report.selections))

    -- The click counters are the discriminator when a click "does nothing":
    -- zero log clicks with a chained row means the native OnClick never
    -- reached us, which is a different fault from a click that arrived and
    -- could not be matched to a quest.
    if clicks then
        local click = clicks:GetReport()
        Line("  click surfaces: " .. tostring(click.chainedRows) .. " quest log rows chained, "
            .. tostring(click.watchLinesMapped) .. " tracker lines mapped")
        Line("  clicks seen: " .. tostring(click.logClicks) .. " quest log, "
            .. tostring(click.watchClicks) .. " tracker; modifier="
            .. tostring(click.modifier))
    end
end

local function ChangeMainQuest(target)
    local mainQuest = UQ:GetModule("MainQuest")
    if not mainQuest then
        Line("the main quest module is unavailable")
        return
    end

    local trimmed = UQ.Trim(target) or ""
    if trimmed == "" then
        ShowMainQuest()
        return
    end
    if string.lower(trimmed) == "clear" or string.lower(trimmed) == "none" then
        if mainQuest:Clear("cleared by command") then
            Line("stopped following")
        else
            Line("not following any quest")
        end
        return
    end

    local titleKey, questOrReason, titles = mainQuest:ResolveTarget(trimmed)
    if not titleKey then
        if questOrReason == "ambiguous" then
            Line("'" .. trimmed .. "' matches several quests:")
            local index = 1
            local total = table.getn(titles or {})
            while index <= total do
                Line("  " .. titles[index])
                index = index + 1
            end
        elseif questOrReason == "noQuestAtIndex" then
            Line("no quest at quest log index " .. trimmed)
        else
            Line("no quest in the log matches '" .. trimmed .. "'")
        end
        return
    end

    mainQuest:Set(titleKey)
    Line("following: |cff" .. UQ.colors.accentHex
        .. tostring(questOrReason.title) .. "|r")
end

-- Waypoint --------------------------------------------------------------------

local function ShowWaypoint()
    local waypoint = UQ:GetModule("Waypoint")
    local heading = UQ:GetModule("PlayerHeading")
    if not waypoint then
        Line("the waypoint module is unavailable")
        return
    end

    local report = waypoint:GetReport()
    Line("HUD waypoint marker")
    Line("  enabled=" .. tostring(report.enabled)
        .. " created=" .. tostring(report.created)
        .. " shown=" .. tostring(report.shown))
    Line("  placements=" .. tostring(report.placements)
        .. " failures=" .. tostring(report.placementFailures))

    if report.shown then
        local yards = report.distanceYards
        Line("  distance " .. (yards and string.format("%.0f", yards) or "?")
            .. " yd, clamped=" .. tostring(report.clamped)
            .. ", area " .. tostring(report.areaId))
    elseif report.hiddenReason then
        Line("  hidden: " .. tostring(report.hiddenReason))
    end

    -- Why the marker is not showing, as a tally. "noMainQuest" means nothing
    -- is selected; "noFacing" means this client gave up no facing at all and
    -- the player has not moved; anything zone-shaped means the quest is not
    -- in the current zone, which is the same limit the map pins have.
    local counts = report.hiddenCounts or {}
    local reason, count
    local any = false
    for reason, count in pairs(counts) do
        if not any then
            Line("  hidden reasons seen:")
            any = true
        end
        Line("    " .. tostring(reason) .. " x" .. tostring(count))
    end

    if heading then
        local headingReport = heading:GetReport()
        Line("  facing: " .. (headingReport.facing
                and string.format("%.2f rad", headingReport.facing) or "none")
            .. " via " .. tostring(headingReport.source or "nothing")
            .. (headingReport.stale and " (stale)" or ""))
        Line("  heading samples=" .. tostring(headingReport.samples)
            .. " movement fixes=" .. tostring(headingReport.movementFixes)
            .. " client source=" .. tostring(headingReport.clientSource or "none"))
        if not headingReport.facing then
            Line("  |cffff5555no facing source|r -- run /urp probe facing, turn a full circle, then /urp probe facing stop")
        end
    end
end

-- Diagnostic only: no probe covers QuestLogFrame's real child/region layout
-- on this client (query_compat.py has nothing but generic Vanilla API docs
-- for it), so this walks it live and prints what is actually there. Used to
-- find a real anchor for the quest-log Show/Track buttons.
local function DumpFrame(label, frame, depth)
    if not frame then
        Line(label .. ": not found")
        return
    end
    Line(label .. ": " .. tostring(Client.GetObjectType(frame))
        .. " " .. tostring(Client.GetObjectName(frame)))
    local regions = Client.GetRegionList(frame) or {}
    local index = 1
    local total = table.getn(regions)
    while index <= total do
        local region = regions[index]
        local point, relativeName, relativePoint, x, y = Client.GetPointInfo(region)
        Line("  region " .. tostring(Client.GetObjectType(region)) .. " "
            .. tostring(Client.GetObjectName(region))
            .. " text=" .. tostring(Client.GetWidgetText(region))
            .. " point=" .. tostring(point) .. "->" .. tostring(relativeName)
            .. " " .. tostring(relativePoint) .. " " .. tostring(x) .. "," .. tostring(y))
        index = index + 1
    end
    local children = Client.GetChildList(frame) or {}
    index = 1
    total = table.getn(children)
    while index <= total do
        local child = children[index]
        local point, relativeName, relativePoint, x, y = Client.GetPointInfo(child)
        Line("  child " .. tostring(Client.GetObjectType(child)) .. " "
            .. tostring(Client.GetObjectName(child))
            .. " point=" .. tostring(point) .. "->" .. tostring(relativeName)
            .. " " .. tostring(relativePoint) .. " " .. tostring(x) .. "," .. tostring(y))
        if depth and depth > 0 then
            DumpFrame("    " .. tostring(Client.GetObjectName(child) or "?"), child, depth - 1)
        end
        index = index + 1
    end
end

local function ShowQuestLogDump()
    local logFrame = Client.GetNamedObject("QuestLogFrame")
    if not logFrame or not Client.IsObjectShown(logFrame) then
        Line("open the quest log and select a quest first")
        return
    end
    DumpFrame("QuestLogFrame", logFrame, 1)
    DumpFrame("QuestLogDetailScrollFrame", Client.GetNamedObject("QuestLogDetailScrollFrame"), 1)
end

-- Opens the options page in whichever window is hosting it. The command is the
-- same either way; which window opens is Core/Settings.lua's decision and is
-- reported by the unrealUISettingsHost line in /uq status.
local function ShowConfig(target)
    local settings = UQ:GetModule("Settings")
    if not settings then
        Line("the settings module is not loaded")
        return
    end

    if target == "button" or target == "button on" or target == "button off" then
        local report = settings:GetReport()
        if report.host == "unrealui" then
            Line("unrealUI's own settings button is already beside the minimap and opens this page")
            return
        end
        local enabled = nil
        if target == "button on" then
            enabled = true
        elseif target == "button off" then
            enabled = false
        end
        if settings:SetMinimapButtonEnabled(enabled) then
            Line("the settings button beside the minimap is shown ("
                .. tostring(settings:GetReport().minimapAnchor) .. ")")
        else
            Line("the settings button beside the minimap is hidden")
        end
        return
    end

    if not settings:Toggle() then
        local report = settings:GetReport()
        if report.host ~= "unrealui" then
            Line("the options window could not be opened; every option is still on /uq")
        end
    end
end

local function Handler(message)
    local argument = UQ.Trim(message) or ""
    local command = ""
    local target = ""
    -- string.gfind is available in the conservative client Lua subset;
    -- string.match is not used because it was introduced later.
    for foundCommand, foundTarget in string.gfind(argument, "(%S+)%s*(.*)") do
        command = string.lower(foundCommand)
        target = foundTarget
    end

    if command == "" or command == "help" then
        ShowHelp()
    elseif command == "config" or command == "settings" or command == "options" then
        ShowConfig(string.lower(UQ.Trim(target) or ""))
    elseif command == "status" then
        ShowStatus()
    elseif command == "quests" or command == "quest" then
        ShowQuests()
    elseif command == "events" then
        ShowEvents()
    elseif command == "map" then
        ShowMap(target)
    elseif command == "minimap" then
        ShowMinimap(target)
    elseif command == "db" or command == "database" then
        ShowDatabase()
    elseif command == "tooltip" then
        ShowTooltip()
    elseif command == "tracker" then
        ShowTracker(UQ.Trim(target) or "")
    elseif command == "main" then
        if UQ:IsFeatureEnabled("mainQuestWaypoint") then
            ChangeMainQuest(target)
        else
            FeatureDisabledNotice()
        end
    elseif command == "waypoint" then
        if UQ:IsFeatureEnabled("mainQuestWaypoint") then
            ShowWaypoint()
        else
            FeatureDisabledNotice()
        end
    elseif command == "track" or command == "untrack" or command == "toggle" then
        ChangeTracking(target, command)
    elseif command == "hide" or command == "unhide" then
        ChangeMapVisibility(target, command == "hide")
    elseif command == "hidden" then
        ShowHiddenQuests()
    elseif command == "resetmarked" then
        ResetMarkedQuests(target)
    elseif command == "pfquest" then
        ImportPfQuestHistory(target)
    elseif command == "marks" or command == "mark" then
        ShowMarks(UQ.Trim(target) or "")
    elseif command == "worldscan" then
        ShowWorldScan(UQ.Trim(target) or "")
    elseif command == "questlog" then
        ShowQuestLogDump()
    elseif command == "debug" then
        local config = UQ:GetModule("Config")
        UQ.debug = not UQ.debug
        if config then
            config:Set("debug", UQ.debug)
        end
        if UQ.debug then
            Line("debug output enabled")
        else
            Line("debug output disabled")
        end
    else
        Line("unknown command: " .. command)
        ShowHelp()
    end
end

function Commands:OnInit()
    SLASH_UNREALQUEST1 = "/uq"
    SLASH_UNREALQUEST2 = "/unrealquest"
    SlashCmdList.UNREALQUEST = Handler
end
