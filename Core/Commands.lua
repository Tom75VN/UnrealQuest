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

-- The help list is one catalog key per row, and each row carries its OWN
-- command spelling. The commands themselves are never translated -- typing
-- them is how they work -- so the key holds the fixed "/uq ..." prefix and the
-- translatable description that follows it, which lets a language pad the
-- column to whatever width its own words need.
local HELP_KEYS = {
    "CMD_HELP_CONFIG",
    "CMD_HELP_CONFIG_BUTTON",
    "CMD_HELP_STATUS",
    "CMD_HELP_QUESTS",
    "CMD_HELP_EVENTS",
    "CMD_HELP_MAP",
    "CMD_HELP_MAP_STYLE",
    "CMD_HELP_MAP_VENDORS",
    "CMD_HELP_MINIMAP",
    "CMD_HELP_MINIMAP_ONOFF",
    "CMD_HELP_MINIMAP_SPAN",
    "CMD_HELP_MINIMAP_INDOORS",
    "CMD_HELP_DB",
    "CMD_HELP_TOOLTIP",
    "CMD_HELP_TRACKER",
    "CMD_HELP_TRACKER_ONOFF",
    "CMD_HELP_TRACKER_RESET",
    "CMD_HELP_TRACKER_OBJECTIVES",
    "CMD_HELP_TRACKER_ZONES",
    "CMD_HELP_TRACKER_RECENT",
    "CMD_HELP_TRACKER_WIDTH",
    "CMD_HELP_TRACKER_HEIGHT",
    "CMD_HELP_TRACKER_UNFOLD",
    "CMD_HELP_TRACKER_UNHIDEALL",
    "CMD_HELP_TRACKER_NATIVE",
}

local HELP_MAIN_KEYS = {
    "CMD_HELP_MAIN_SET",
    "CMD_HELP_MAIN_REPORT",
    "CMD_HELP_MAIN_CLEAR",
    "CMD_HELP_NAV",
}

local HELP_TAIL_KEYS = {
    "CMD_HELP_TRACK",
    "CMD_HELP_UNTRACK",
    "CMD_HELP_TOGGLE",
    "CMD_HELP_HIDE",
    "CMD_HELP_UNHIDE",
    "CMD_HELP_HIDDEN",
    "CMD_HELP_RESETMARKED",
    "CMD_HELP_RESETMARKED_ALL",
    "CMD_HELP_PFQUEST",
    "CMD_HELP_PFQUEST_IMPORT",
    "CMD_HELP_PFQUEST_UNDO",
    "CMD_HELP_RARE",
    "CMD_HELP_RARE_ONOFF",
    "CMD_HELP_RARE_RANGE",
    "CMD_HELP_RARE_SOUND",
    "CMD_HELP_RARE_TEST",
    "CMD_HELP_RARE_RESET",
    "CMD_HELP_MARKS",
    "CMD_HELP_MARKS_ONOFF",
    "CMD_HELP_MARKS_ICON",
    "CMD_HELP_MARKS_GROUP",
    "CMD_HELP_WORLDSCAN",
    "CMD_HELP_WORLDSCAN_CHILD",
    "CMD_HELP_DEBUG",
}

local function HelpBlock(keys)
    local index = 1
    local total = table.getn(keys)
    while index <= total do
        Line("  " .. UQ.L(keys[index]))
        index = index + 1
    end
end

local function ShowHelp()
    Line(UQ.L("CMD_HELP_TITLE", UQ.version))
    HelpBlock(HELP_KEYS)
    if UQ:IsFeatureEnabled("mainQuestWaypoint") then
        HelpBlock(HELP_MAIN_KEYS)
    else
        Line("  |cff888888" .. UQ.L("CMD_HELP_MAIN_DISABLED") .. "|r")
    end
    HelpBlock(HELP_TAIL_KEYS)
end

local function ShowStatus()
    Line(UQ.L("CMD_STATUS_TITLE", UQ.version))
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
            Line("  |cffff5555" .. UQ.L("CMD_STATE_DISABLED") .. "|r  " .. key
                .. " |cff888888" .. tostring(feature.note) .. "|r")
        end
        featureIndex = featureIndex + 1
    end

    local state = UQ:GetModule("QuestState")
    if state then
        local completeness = UQ.L("CMD_STATUS_SNAPSHOT_COMPLETE")
        if not state:IsComplete() then
            completeness = UQ.LN("CMD_STATUS_SNAPSHOT_INCOMPLETE", state.collapsedHeaders)
        end
        Line("  " .. UQ.LN("CMD_STATUS_QUEST_LOG", state:GetQuestCount(), completeness))
    end

    Line("  " .. UQ.L("CMD_STATUS_OBJECTIVE_PATH", Client.GetObjectiveMode()))
end

local function ShowQuests()
    local state = UQ:GetModule("QuestState")
    if not state then
        Line(UQ.L("CMD_MODULE_MISSING_QUEST_STATE"))
        return
    end
    local quests = state:GetOrderedQuests()
    local total = table.getn(quests)
    if total == 0 then
        Line(UQ.L("CMD_QUESTS_NONE"))
        return
    end
    if not state:IsComplete() then
        Line("|cffffff55" .. UQ.LN("CMD_QUESTS_SNAPSHOT_INCOMPLETE", state.collapsedHeaders) .. "|r")
    end
    -- Non-zero means something between the client and this addon is prefixing
    -- levels onto quest titles. The titles below are the stripped ones, so the
    -- count is the only place that shows it happened at all.
    local decorated = Client.GetQuestTitleDecorationCount and Client.GetQuestTitleDecorationCount()
    if decorated and decorated > 0 then
        Line("|cff888888" .. UQ.LN("CMD_QUESTS_LEVEL_PREFIXES", decorated) .. "|r")
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
            complete = " |cff55ff55" .. UQ.L("CMD_QUESTS_FLAG_COMPLETE") .. "|r"
        elseif quest.isComplete == -1 then
            complete = " |cffff5555" .. UQ.L("CMD_QUESTS_FLAG_FAILED") .. "|r"
        end
        local tracked = ""
        local tracker = UQ:GetModule("Tracker")
        if tracker and tracker:IsTracked(quest) then
            tracked = " |cff" .. UQ.colors.accentHex .. UQ.L("CMD_QUESTS_FLAG_TRACKED") .. "|r"
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
        Line(UQ.L("CMD_MODULE_MISSING_EVENTS"))
        return
    end
    Line(UQ.L("CMD_EVENTS_TITLE"))
    local report = events:GetRegistrationReport()
    local index = 1
    local total = table.getn(report)
    while index <= total do
        local entry = report[index]
        local mark
        if entry.accepted then
            mark = "|cff55ff55" .. UQ.L("CMD_EVENTS_ACCEPTED") .. "|r"
        else
            mark = "|cffff5555" .. UQ.L("CMD_EVENTS_REJECTED") .. "|r"
        end
        Line("  " .. mark .. "  " .. entry.event .. "  "
            .. UQ.L("CMD_EVENTS_FIRED", tostring(entry.observed)))
        index = index + 1
    end
    Line("|cff888888" .. UQ.L("CMD_EVENTS_FOOTNOTE") .. "|r")
end

local function ShowMap(target)
    local map = UQ:GetModule("MapContext")
    if not map then
        Line(UQ.L("CMD_MODULE_MISSING_MAP"))
        return
    end

    -- The same switch as the options page's "Show quest objectives as dots".
    -- Writing the setting is all this has to do: WorldMapPins carries it in
    -- its view signature and repaints on the next refresh.
    target = string.lower(UQ.Trim(target) or "")
    if target == "dots" or target == "areas" then
        local config = UQ:GetModule("Config")
        if not config then
            Line(UQ.L("CMD_MODULE_MISSING_CONFIG"))
            return
        end
        config:Set("mapObjectiveDots", target == "dots")
        if target == "dots" then
            Line(UQ.L("CMD_MAP_STYLE_SET_DOTS"))
        else
            Line(UQ.L("CMD_MAP_STYLE_SET_AREAS"))
        end
        return
    end

    -- The same shape one line up, for the vendor points of quest items that
    -- are bought (Map/QuestVendorPins.lua). That layer reads the setting on
    -- its own refresh, so writing it is the whole job; `dirty` only saves the
    -- player a view change before it takes effect.
    local vendorWord, vendorEnd = string.find(target, "^vendors")
    if vendorWord then
        local argument = UQ.Trim(string.sub(target, vendorEnd + 1)) or ""
        if argument ~= "on" and argument ~= "off" then
            Line(UQ.L("CMD_MAP_VENDORS_USAGE"))
            return
        end
        local config = UQ:GetModule("Config")
        if not config then
            Line(UQ.L("CMD_MODULE_MISSING_CONFIG"))
            return
        end
        config:Set("questVendorPins", argument == "on")
        local vendorPins = UQ:GetModule("QuestVendorPins")
        if vendorPins then
            vendorPins.dirty = true
        end
        if argument == "on" then
            Line(UQ.L("CMD_MAP_VENDORS_SET_ON"))
        else
            Line(UQ.L("CMD_MAP_VENDORS_SET_OFF"))
        end
        return
    end
    local report = map:Inspect()
    Line(UQ.L("CMD_MAP_TITLE"))
    Line("  " .. UQ.L("CMD_MAP_MAPFILE", tostring(report.mapFile)))
    Line("  " .. UQ.L("CMD_MAP_TILE_SIZE",
        tostring(report.tileHeight) .. " / " .. tostring(report.tileWidth)))
    Line("  " .. UQ.L("CMD_MAP_CONTINENT_ZONE",
        tostring(report.continent) .. " / " .. tostring(report.zoneIndex)))
    Line("  " .. UQ.L("CMD_MAP_ZONE_TEXT", tostring(report.zoneText)))
    Line("  " .. UQ.L("CMD_MAP_SUBZONE_TEXT", tostring(report.subZoneText)))
    Line("  " .. UQ.L("CMD_MAP_PLAYER_POSITION",
        tostring(report.playerX) .. ", " .. tostring(report.playerY)))
    Line("  " .. UQ.L("CMD_MAP_AREA_FROM_MAPFILE", tostring(report.areaIdFromMapFile),
        tostring(report.areaIdFromMapFileHow)))
    Line("  " .. UQ.L("CMD_MAP_AREA_FROM_ZONE_TEXT", tostring(report.areaIdFromZoneText),
        tostring(report.areaIdFromZoneTextHow)))
    Line("  " .. UQ.L("CMD_MAP_AREA_FROM_REAL_ZONE_TEXT", tostring(report.areaIdFromRealZoneText),
        tostring(report.areaIdFromRealZoneTextHow)))
    Line("  " .. UQ.L("CMD_MAP_ZONE_NAME", tostring(report.mapZoneName)))
    Line("  " .. UQ.L("CMD_MAP_AREA_FROM_MAP_ZONE", tostring(report.areaIdFromMapZone),
        tostring(report.areaIdFromMapZoneHow)))
    Line("  " .. UQ.L("CMD_MAP_AREA_USED", tostring(report.areaId),
        tostring(report.areaIdHow)))
    local pins = UQ:GetModule("WorldMapPins")
    if pins then
        local status = pins:GetStatus()
        if not status.renderEnabled then
            Line("  " .. UQ.L("CMD_MAP_OVERLAY_DISABLED"))
        elseif status.markersEnabled then
            Line("  " .. UQ.L("CMD_MAP_QUEST_MARKERS",
                tostring(status.visible), tostring(status.pooled)))
        else
            Line("  " .. UQ.L("CMD_MAP_QUEST_MARKERS_RETIRED"))
        end
        -- Read next to itemUseUnknown below: "unreadable" there plus "unknown"
        -- here is a dead container API; "unreadable" there with the bags
        -- reporting items is a data or matching problem instead.
        local bags = UQ:GetModule("BagItems")
        local bagStatus = bags and bags:GetStatus()
        local bagLine = nil
        if bagStatus then
            if bagStatus.available then
                bagLine = UQ.LN("CMD_MAP_BAGS_ITEMS", bagStatus.distinctItems)
            else
                bagLine = UQ.L("CMD_MAP_BAGS_UNREADABLE")
            end
        end
        if status.renderEnabled and status.areasEnabled then
            Line("  " .. UQ.L("CMD_MAP_OBJECTIVE_STYLE",
                status.objectiveDots and UQ.L("CMD_MAP_STYLE_DOTS")
                    or UQ.L("CMD_MAP_STYLE_AREAS")))
            Line("  " .. UQ.L("CMD_MAP_OBJECTIVE_FRAMES",
                tostring(status.areaVisible), tostring(status.areaPooled)))
            Line("  " .. UQ.L("CMD_MAP_COLOURS")
                .. (status.markersEnabled and UQ.L("CMD_MAP_COLOURS_MARKERS") or ""))
            -- Marker counts, read together with the hover counters below: a
            -- non-zero count with nothing on screen means the client's gossip
            -- icon file did not resolve, which is the one unverified thing
            -- about both pools.
            Line("  " .. UQ.L("CMD_MAP_GIVER_MARKERS",
                tostring(status.giverVisible), tostring(status.giverPooled)))
            -- Invisible by construction (Map/WorldMapPins.lua): this is the
            -- route's hit test, not something the player can see. A zero here
            -- with a drawn route means the path is unhoverable.
            Line("  " .. UQ.L("CMD_MAP_PATROL_TARGETS",
                tostring(status.patrolVisible), tostring(status.patrolPooled)))
            -- A width above the floor means the pool bound widened the spacing
            -- and the stamps were grown to keep the stroke continuous. Read it
            -- when a route looks heavier than it should.
            Line("  " .. UQ.L("CMD_MAP_PATROL_STROKES",
                tostring(status.patrolStrokes), tostring(status.patrolStrokeWidth)))
            Line("  " .. UQ.L("CMD_MAP_TURNIN_MARKERS",
                tostring(status.turnInVisible), tostring(status.turnInPooled))
                .. (status.inProgressTurnIns and ""
                    or (" " .. UQ.L("CMD_MAP_TURNIN_READY_ONLY"))))
            -- Item-use objective targets left off the map because the bags
            -- could not be read, not because the item is missing. This is the
            -- answer to "I am carrying the quest item and its target still is
            -- not shown": non-zero blames the container API, and /uq status
            -- will show bagScan alongside it.
            Line("  " .. UQ.L("CMD_MAP_ITEM_USE_UNRESOLVED", tostring(status.itemUseUnknown))
                .. (bagLine and (" " .. UQ.L("CMD_MAP_BAGS", bagLine)) or ""))
            -- Zero here after a session spent hovering areas is the symptom of
            -- the recorded "custom map child receives no mouse" failure, not of
            -- an empty quest log.
            Line("  " .. UQ.L("CMD_MAP_AREA_HOVERS", tostring(status.areaHovers)))
            -- Zero here after shift-clicking a "!" is the symptom of the open
            -- worldMapPinInteraction question, not of QuestHistory failing to
            -- mark the quest done -- OnClick may simply never have reached
            -- this smaller pin at all.
            Line("  " .. UQ.L("CMD_MAP_GIVER_HOVERS_CLICKS",
                tostring(status.giverHovers), tostring(status.giverClicks)))
            -- The "?" pins take no clicks, so hovers are all they can report.
            -- Read against area hovers: the turn-in pin usually sits on top of
            -- a green area tile, so zero here with area hovers rising means
            -- the tile is still winning the mouse.
            Line("  " .. UQ.L("CMD_MAP_TURNIN_HOVERS", tostring(status.turnInHovers)))
            -- Rising after a shift-click means the overlay did rebuild, so a
            -- marker still on screen is a stale fullscreen-map paint rather
            -- than a stale quest layer.
            Line("  " .. UQ.L("CMD_MAP_OVERLAY_REBUILDS", tostring(status.rebuilds)))
        elseif status.renderEnabled then
            Line("  " .. UQ.L("CMD_MAP_AREAS_UNAVAILABLE"))
            Line("  " .. UQ.L("CMD_MAP_MARKER_COLOURS"))
        end
    end

    -- Its own layer, so its own line: a quest whose item is bought has no
    -- objective area at all, and a zero here with the setting on is the
    -- difference between "no such quest in the log" and "the layer is not
    -- drawing".
    local vendorPins = UQ:GetModule("QuestVendorPins")
    if vendorPins then
        local vendorStatus = vendorPins:GetStatus()
        Line("  " .. UQ.L("CMD_MAP_VENDOR_PINS",
            vendorStatus.enabled and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF"),
            tostring(vendorStatus.worldVisible), tostring(vendorStatus.minimapVisible)))
    end
end

local function ShowMinimap(target)
    target = string.lower(UQ.Trim(target) or "")
    local pins = UQ:GetModule("MinimapPins")
    local config = UQ:GetModule("Config")
    if not pins or not config then
        Line(UQ.L("CMD_MODULE_MISSING_MINIMAP"))
        return
    end

    if target == "on" or target == "off" then
        config:Set("minimapPins", target == "on")
        pins.dirty = true
        pins:Refresh()
        if target == "on" then
            Line(UQ.L("CMD_MINIMAP_PINS_ON"))
        else
            Line(UQ.L("CMD_MINIMAP_PINS_OFF"))
        end
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
            Line(UQ.L("CMD_MINIMAP_INDOORS_WITHHELD"))
        else
            Line(UQ.L("CMD_MINIMAP_INDOORS_DRAWN"))
        end
        return
    end

    local spanWord, spanValue = string.find(target, "^span")
    if spanWord then
        local argument = UQ.Trim(string.sub(target, spanValue + 1)) or ""
        local yards = tonumber(argument)
        if argument == "" then
            local status = pins:GetStatus()
            Line(UQ.L("CMD_MINIMAP_SPAN_AT_ZOOM", tostring(status.zoom),
                tostring(status.span), tostring(status.spanEvidence)))
            Line("  " .. UQ.L("CMD_MINIMAP_SPAN_HELP_SET"))
            Line("  " .. UQ.L("CMD_MINIMAP_SPAN_HELP_RESET"))
            Line("  |cff888888" .. UQ.L("CMD_MINIMAP_SPAN_HELP_HINT") .. "|r")
            return
        end
        if argument == "reset" then
            yards = nil
        elseif not yards or yards <= 0 then
            Line(UQ.L("CMD_MINIMAP_SPAN_USAGE"))
            return
        end
        local key, zoom, indoor, span, evidence = pins:SetSpanOverride(yards)
        if not key then
            Line(UQ.L("CMD_MINIMAP_SPAN_NO_ZOOM"))
            return
        end
        Line(UQ.L("CMD_MINIMAP_SPAN_SET", tostring(zoom),
            tostring(indoor or UQ.L("CMD_MINIMAP_ENVIRONMENT_UNKNOWN")),
            tostring(span), tostring(evidence)))
        return
    end

    local status = pins:GetStatus()
    Line(UQ.L("CMD_MINIMAP_TITLE"))
    Line("  " .. UQ.L("CMD_MINIMAP_SETTING",
        config:Get("minimapPins") and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF")))
    Line("  " .. UQ.L("CMD_MINIMAP_STATE", tostring(status.state)))
    Line("  " .. UQ.L("CMD_MINIMAP_DRAWN", tostring(status.objectives),
        tostring(status.givers), tostring(status.turnIns)))
    Line("  " .. UQ.L("CMD_MINIMAP_CLAMPED", tostring(status.clamped), tostring(status.targets)))
    Line("  " .. UQ.L("CMD_MINIMAP_WIDTH", tostring(status.width), tostring(status.zoom)))
    Line("  " .. UQ.L("CMD_MINIMAP_SCALE", tostring(status.span),
        tostring(status.spanEvidence)))
    if status.spanEvidence ~= "measured" then
        Line("  |cffffcc00" .. UQ.L("CMD_MINIMAP_ONLY_ZOOM_ZERO") .. "|r")
    end
    if status.rotating then
        Line("  |cffff5555" .. UQ.L("CMD_MINIMAP_ROTATING") .. "|r")
    end
    if status.spanEvidence ~= "playerCalibrated" then
        Line("  |cff888888" .. UQ.L("CMD_MINIMAP_SPAN_TIP") .. "|r")
    end
    if config:Get("minimapPinsHideIndoors") ~= false then
        Line("  " .. UQ.L("CMD_MINIMAP_INDOORS_STATUS_WITHHELD"))
    else
        Line("  " .. UQ.L("CMD_MINIMAP_INDOORS_STATUS_DRAWN"))
    end
    if status.pinFailures and status.pinFailures > 0 then
        Line("  " .. UQ.L("CMD_MINIMAP_PIN_FAILURES", tostring(status.pinFailures)))
    end
end

-- "/uq rare", and its four settings. The range and the sound kit are here
-- rather than on the options page for the reason named in Core/Settings.lua:
-- an unknown SoundEntries kit name is SILENT on this client rather than an
-- error, so choosing one means hearing it, and "/uq rare sound <kit>" plays
-- the kit as it stores it.
local function ShowRareAlert(target)
    -- Two copies on purpose. Sub-commands are matched case-insensitively, but
    -- a SoundEntries kit name is mixed case ("igMainMenuOption") and the client
    -- looks it up by name, so the sound branch must read the ORIGINAL text.
    local original = UQ.Trim(target) or ""
    target = string.lower(original)
    local alert = UQ:GetModule("RareAlert")
    local config = UQ:GetModule("Config")
    if not alert or not config then
        Line(UQ.L("CMD_MODULE_MISSING_RARE"))
        return
    end

    if target == "on" or target == "off" then
        config:Set("rareAlert", target == "on")
        if target == "on" then
            Line(UQ.L("CMD_RARE_ON"))
        else
            alert:Dismiss()
            Line(UQ.L("CMD_RARE_OFF"))
        end
        return
    end

    if target == "test" then
        local name, why = alert:Test()
        if name then
            Line(UQ.L("CMD_RARE_TEST_OK", name))
        else
            Line(UQ.L("CMD_RARE_TEST_FAILED", tostring(why)))
        end
        return
    end

    -- Position only. There is no other state on this card worth a "reset", and
    -- the alert's own settings each have their own sub-command above.
    if target == "reset" then
        alert:ResetPosition()
        Line(UQ.L("CMD_RARE_POSITION_RESET"))
        return
    end

    local rangeWord, rangeEnd = string.find(target, "^range")
    if rangeWord then
        local argument = UQ.Trim(string.sub(target, rangeEnd + 1)) or ""
        local yards = tonumber(argument)
        if not yards or yards < 20 or yards > 500 then
            Line(UQ.L("CMD_RARE_RANGE_USAGE"))
            return
        end
        config:Set("rareAlertRange", yards)
        Line(UQ.L("CMD_RARE_RANGE_SET", tostring(alert:GetRange())))
        return
    end

    local soundWord, soundEnd = string.find(target, "^sound")
    if soundWord then
        local kit = UQ.Trim(string.sub(original, soundEnd + 1)) or ""
        if kit == "" then
            Line(UQ.L("CMD_RARE_SOUND_USAGE"))
            Line("  |cff888888" .. UQ.L("CMD_RARE_SOUND_HINT") .. "|r")
            return
        end
        config:Set("rareAlertSound", kit)
        Client.PlayAlertSound(kit)
        Line(UQ.L("CMD_RARE_SOUND_SET", kit))
        Line("  |cff888888" .. UQ.L("CMD_RARE_SOUND_HINT") .. "|r")
        return
    end

    local status = alert:GetStatus()
    Line(UQ.L("CMD_RARE_TITLE"))
    Line("  " .. UQ.L("CMD_RARE_SETTING",
        status.enabled and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF")))
    Line("  " .. UQ.L("CMD_RARE_RANGE", tostring(status.range), tostring(status.seconds)))
    Line("  " .. UQ.L("CMD_RARE_SOUND", tostring(status.sound), tostring(status.soundPlayed)))
    if not status.soundAvailable then
        Line("  |cffff5555" .. UQ.L("CMD_RARE_SOUND_MISSING") .. "|r")
    end
    Line("  " .. UQ.L("CMD_RARE_STATE", tostring(status.state),
        tostring(status.areaId or UQ.L("COMMON_NONE"))))
    Line("  " .. UQ.L("CMD_RARE_INDEX",
        status.indexReady and UQ.L("COMMON_YES") or UQ.L("COMMON_NO"),
        tostring(status.indexedCreatures), tostring(status.candidates)))
    Line("  " .. UQ.L("CMD_RARE_COUNTS", tostring(status.alerts), tostring(status.scans)))
    if status.lastName then
        Line("  " .. UQ.L("CMD_RARE_LAST", status.lastName,
            tostring(status.lastRank or UQ.L("COMMON_UNKNOWN")),
            tostring(status.lastDistance)))
    end
    Line("  |cff888888" .. UQ.L("CMD_RARE_PROXIMITY_NOTE") .. "|r")
end

local function ShowDatabase()
    local database = UQ:GetModule("Database")
    if not database then
        Line(UQ.L("CMD_MODULE_MISSING_DATABASE"))
        return
    end
    Line(UQ.L("CMD_DB_WORLD_DATA", database:GetStatus()))
    if database.available then
        Line("  " .. UQ.L("CMD_DB_TITLES_INDEXED", tostring(database.indexedCount)))
        local matcher = UQ:GetModule("QuestMatch")
        if matcher then
            Line("  " .. UQ.L("CMD_DB_UNMATCHED", tostring(matcher:GetUnmatchedCount())))
        end
    else
        Line("  |cffff5555" .. UQ.L("CMD_DB_NOT_LOADED") .. "|r")
    end
end

local function ShowTooltip()
    local tooltip = UQ:GetModule("EntityTooltip")
    if not tooltip then
        Line(UQ.L("CMD_MODULE_MISSING_TOOLTIP"))
        return
    end
    local status = tooltip:GetStatus()
    Line(UQ.L("CMD_TOOLTIP_TITLE"))
    -- See Tooltip/EntityTooltip.lua's diagnostics comment block for how to
    -- read these together -- they split the pipeline into stages so a silent
    -- failure can be narrowed down without a screenshot.
    Line("  " .. UQ.L("CMD_TOOLTIP_REFRESH_CALLS", tostring(status.refreshCount)))
    if not status.refreshCount or status.refreshCount == 0 then
        Line("  |cffff5555" .. UQ.L("CMD_TOOLTIP_NEVER_RAN") .. "|r")
    end
    Line("  " .. UQ.L("CMD_TOOLTIP_FORMATS_RESOLVED", tostring(status.patternsResolved),
        tostring(status.patternsExpected)))
    if status.patternsResolved == 0 then
        Line("  |cffff5555" .. UQ.L("CMD_TOOLTIP_NO_FORMAT") .. "|r")
    end
    Line("  " .. UQ.L("CMD_TOOLTIP_NAMES_READ", tostring(status.labelReads)))
    Line("  " .. UQ.L("CMD_TOOLTIP_LAST_TEXT",
        tostring(status.lastSeenLabel or UQ.L("COMMON_NONE_ANGLED"))))
    if status.refreshCount and status.refreshCount > 0 and status.labelReads == 0 then
        Line("  |cffff5555" .. UQ.L("CMD_TOOLTIP_NO_TEXT_RETURNED") .. "|r")
    end
    Line("  " .. UQ.L("CMD_TOOLTIP_MOUSEOVERS", tostring(status.matches),
        tostring(status.directMatches), tostring(status.databaseMatches)))
    if status.labelReads > 0 and status.matches == 0 then
        Line("  |cffff5555" .. UQ.L("CMD_TOOLTIP_NEVER_MATCHED") .. "|r")
    end
    Line("  " .. UQ.L("CMD_TOOLTIP_PRESENTATION_FAILURES",
        tostring(status.presentationFailures)))
    if status.matches > 0 and status.presentationFailures >= status.matches then
        Line("  |cffff5555" .. UQ.L("CMD_TOOLTIP_ALL_PRESENTATIONS_FAILED") .. "|r")
    end
    Line("  " .. UQ.L("CMD_TOOLTIP_CURRENT_UNIT", tostring(status.currentUnit)))
end

local function ShowMarks(target)
    local marks = UQ:GetModule("QuestMarks")
    if not marks then
        Line(UQ.L("CMD_MODULE_MISSING_MARKS"))
        return
    end
    local config = UQ:GetModule("Config")

    if target == "on" or target == "off" then
        if config then
            config:Set("questMarks", target == "on")
        end
        if target == "off" then
            marks:ClearReachable()
            Line(UQ.L("CMD_MARKS_OFF"))
        else
            marks.refused = false
            marks.stats.unconfirmed = 0
            Line(UQ.L("CMD_MARKS_ON"))
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
            Line("|cffff5555" .. UQ.L("CMD_MARKS_ICON_USAGE") .. "|r")
            return
        end
        if config then
            config:Set("questMarkIndex", index)
        end
        Line(UQ.L("CMD_MARKS_ICON_SET", marks:MarkName(index)))
        return
    end

    if subCommand == "group" then
        local mode = string.lower(UQ.Trim(rest) or "")
        if mode ~= "on" and mode ~= "off" then
            Line("|cffff5555" .. UQ.L("CMD_MARKS_GROUP_USAGE") .. "|r")
            return
        end
        if config then
            config:Set("questMarksInGroup", mode == "on")
        end
        if mode == "on" then
            Line("|cffffff55" .. UQ.L("CMD_MARKS_GROUP_ON") .. "|r")
        else
            Line(UQ.L("CMD_MARKS_GROUP_OFF"))
        end
        return
    end

    local status = marks:GetStatus()
    Line(UQ.L("CMD_MARKS_TITLE"))
    if not status.available then
        Line("  |cffff5555" .. UQ.L("CMD_MARKS_UNAVAILABLE") .. "|r")
        return
    end
    Line("  " .. UQ.L("CMD_MARKS_ENABLED",
        status.enabled and UQ.L("COMMON_YES") or UQ.L("COMMON_NO"))
        .. "   |cff888888/uq marks on|off|r")
    Line("  " .. UQ.L("CMD_MARKS_MARK_USED", marks:MarkName(status.objectiveIndex),
        marks:MarkName(status.turnInIndex))
        .. "   |cff888888/uq marks icon 1-8|r")
    Line("  " .. UQ.L("CMD_MARKS_IN_GROUP",
        status.inGroup and UQ.L("COMMON_YES") or UQ.L("COMMON_NO"))
        .. (status.allowedHere and "" or (status.inGroup
            and ("  |cffffff55" .. UQ.L("CMD_MARKS_PAUSED") .. "|r")
            or ("  |cffff5555" .. UQ.L("CMD_MARKS_SOLO_REFUSED") .. "|r"))))
    Line("  " .. UQ.L("CMD_MARKS_WRITTEN", tostring(status.writes),
        tostring(status.confirmed), tostring(status.cleared)))
    Line("  " .. UQ.L("CMD_MARKS_LAST_MARKED",
        tostring(status.lastMarked or UQ.L("COMMON_NONE_ANGLED")))
        .. " |cff888888" .. tostring(status.lastKind or "") .. "|r")

    -- The one thing GetRaidTargetIndex alone cannot tell you, said out loud:
    -- the write is a server round trip, so "no confirmation yet" and "the
    -- server refused it" look identical for the first few seconds.
    if not status.inGroup then
        Line("  |cffff5555" .. UQ.L("CMD_MARKS_SOLO_NOTE") .. "|r")
    elseif status.refused then
        Line("  |cffff5555" .. UQ.L("CMD_MARKS_REFUSED_NOTE") .. "|r")
    elseif status.writes > 0 and status.confirmed == 0 then
        Line("  |cffffff55" .. UQ.L("CMD_MARKS_UNCONFIRMED_NOTE") .. "|r")
    elseif status.confirmed > 0 then
        Line("  |cff888888" .. UQ.L("CMD_MARKS_ACCEPTED_NOTE") .. "|r")
    end
end

local function ShowWorldScan(target)
    local scan = UQ:GetModule("WorldFrameScan")
    if not scan then
        Line(UQ.L("CMD_MODULE_MISSING_WORLDSCAN"))
        return
    end

    local childIndex = tonumber(target)
    if childIndex then
        local detail = scan:Detail(childIndex)
        if not detail then
            Line(UQ.L("CMD_WORLDSCAN_NO_CHILD", tostring(childIndex)))
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
    Line(UQ.L("CMD_WORLDSCAN_SUMMARY", tostring(scan.childCount),
        tostring(table.getn(scan.lines))))
    Line("|cff888888" .. UQ.L("CMD_WORLDSCAN_SAVED_NOTE") .. "|r")
end

-- Resolves a command target against the live model, never the raw quest log.
-- Raw indexes include headers, while the model contains quests only; matching
-- through it keeps a header from ever being passed to the watch APIs.
local function FindQuest(target)
    local state = UQ:GetModule("QuestState")
    if not state then
        Line(UQ.L("CMD_MODULE_MISSING_QUEST_STATE"))
        return nil
    end

    target = UQ.Trim(target)
    if not target or target == "" then
        Line(UQ.L("CMD_FIND_USAGE"))
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
        Line(UQ.L("CMD_FIND_NO_INDEX", target))
        return nil
    end

    local targetKey = UQ.NameKey(target)
    if not targetKey then
        Line(UQ.L("CMD_FIND_ENTER_TARGET"))
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
        Line(UQ.L("CMD_FIND_NO_TITLE_MATCH", target))
        return nil
    end

    Line(UQ.L("CMD_FIND_AMBIGUOUS", target))
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
        Line(UQ.L("CMD_MODULE_MISSING_TRACKER"))
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
            Line(UQ.L("CMD_TRACK_ALREADY", quest.title))
            return
        end
        changed = tracker:Track(quest)
    elseif action == "untrack" then
        if not wasTracked then
            Line(UQ.L("CMD_TRACK_NOT_TRACKED", quest.title))
            return
        end
        changed = tracker:Untrack(quest)
    else
        changed = tracker:Toggle(quest)
    end

    if not changed then
        Line(UQ.L("CMD_TRACK_UNCHANGED", quest.title))
        return
    end
    if tracker:IsTracked(quest) then
        Line(UQ.L("CMD_TRACK_NOW_TRACKING", quest.title))
    else
        Line(UQ.L("CMD_TRACK_STOPPED", quest.title))
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
        Line(UQ.L("CMD_MODULE_MISSING_CONFIG"))
        return
    end

    local quest = FindQuest(target)
    if not quest then
        return
    end
    if type(quest.questId) ~= "number" then
        Line(UQ.L("CMD_HIDE_NO_QUEST_ID", tostring(quest.title)))
        return
    end

    -- Stored as an explicit boolean override rather than deleted on unhide:
    -- some quests (see WorldMapPins.DEFAULT_HIDDEN_QUEST_IDS, e.g. CLUCK!) are
    -- hidden by default for every player, so "unhide" has to be able to force
    -- one back on rather than merely clearing an override that was never set.
    if config:SetSectionEntry("hiddenMapQuests", quest.questId, hide) then
        if hide then
            Line(UQ.L("CMD_HIDE_DONE", tostring(quest.title)))
        else
            Line(UQ.L("CMD_UNHIDE_DONE", tostring(quest.title)))
        end
        MarkMapDirty()
    else
        Line(UQ.L("CMD_HIDE_NOT_PERSISTED", tostring(quest.title)))
    end
end

local function ShowHiddenQuests()
    local config = UQ:GetModule("Config")
    local pins = UQ:GetModule("WorldMapPins")
    local database = UQ:GetModule("Database")
    if not config or not pins then
        Line(UQ.L("CMD_MODULE_MISSING_REQUIRED"))
        return
    end

    local section = config:GetSection("hiddenMapQuests")
    local defaults = pins:GetDefaultHiddenQuestIds()
    local any = false
    local questId

    for questId in pairs(defaults) do
        if pins:IsQuestHidden(questId, config) then
            if not any then
                Line(UQ.L("CMD_HIDDEN_TITLE"))
                any = true
            end
            local title = database and database:GetQuestTitle(questId)
            Line("  " .. tostring(questId) .. "  " .. tostring(title or "?")
                .. " |cff888888" .. UQ.L("CMD_HIDDEN_BY_DEFAULT") .. "|r")
        end
    end

    for questId, override in pairs(section) do
        if override == true and defaults[questId] == nil then
            if not any then
                Line(UQ.L("CMD_HIDDEN_TITLE"))
                any = true
            end
            local title = database and database:GetQuestTitle(questId)
            Line("  " .. tostring(questId) .. "  " .. tostring(title or "?"))
        end
    end

    if not any then
        Line(UQ.L("CMD_HIDDEN_NONE"))
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
        Line(UQ.L("CMD_MODULE_MISSING_HISTORY"))
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
            Line(UQ.L("CMD_RESETMARKED_NONE_MANUAL"))
            Line("  " .. UQ.L("CMD_RESETMARKED_TRY_ALL"))
        else
            Line(UQ.L("CMD_RESETMARKED_NONE"))
        end
        return
    end

    local database = UQ:GetModule("Database")
    if all then
        Line(UQ.LN("CMD_RESETMARKED_DONE_ALL", total))
    else
        Line(UQ.LN("CMD_RESETMARKED_DONE_MANUAL", total))
    end
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
        Line(UQ.L("CMD_MODULE_MISSING_PFQUEST"))
        return
    end

    local action = string.lower(UQ.Trim(argument) or "")

    if action == "undo" then
        local total = importer:Undo()
        if total == 0 then
            Line(UQ.L("CMD_PFQUEST_UNDO_NOTHING"))
        else
            Line(UQ.LN("CMD_PFQUEST_UNDO_DONE", total))
            Line("  " .. UQ.L("CMD_PFQUEST_UNDO_LEFT_ALONE"))
        end
        return
    end

    if action ~= "" and action ~= "import" then
        Line(UQ.L("CMD_PFQUEST_UNKNOWN_OPTION", action))
        return
    end

    if action == "" then
        Line(importer:Describe())
        local state = importer:GetState().state
        if state == "ready" then
            Line("  " .. UQ.L("CMD_PFQUEST_HINT_READY"))
        elseif state == "disabled" or state == "unavailable" then
            Line("  " .. UQ.L("CMD_PFQUEST_HINT_DISABLED_1"))
            Line("  " .. UQ.L("CMD_PFQUEST_HINT_DISABLED_2"))
        elseif state == "pending" then
            Line("  " .. UQ.L("CMD_PFQUEST_HINT_PENDING"))
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
        Line("  " .. UQ.LN("CMD_PFQUEST_ALREADY_RECORDED", report.alreadyDone))
    end
    local skipped = report.unknown + report.unmatched + report.ambiguous
    if skipped > 0 then
        Line("  " .. UQ.LN("CMD_PFQUEST_SKIPPED", skipped))
    end
    if report.waiting > 0 then
        Line("  " .. UQ.LN("CMD_PFQUEST_WAITING", report.waiting))
    end
    Line("  " .. UQ.L("CMD_PFQUEST_UNDO_HINT"))
end

-- Quest tracker window -----------------------------------------------------------

local function ShowTracker(argument)
    local tracker = UQ:GetModule("TrackerFrame")
    local config = UQ:GetModule("Config")
    if not tracker or not config then
        Line(UQ.L("CMD_MODULE_MISSING_TRACKER_FRAME"))
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
        Line(UQ.L("CMD_TRACKER_SHOWN"))
        return
    elseif command == "off" or command == "hide" then
        tracker:SetShown(false)
        Line(UQ.L("CMD_TRACKER_HIDDEN"))
        return
    elseif command == "toggle" then
        tracker:SetShown(not tracker:IsShown())
        if tracker:IsShown() then
            Line(UQ.L("CMD_TRACKER_SHOWN"))
        else
            Line(UQ.L("CMD_TRACKER_HIDDEN"))
        end
        return
    elseif command == "reset" then
        tracker:ResetPosition()
        tracker.dirty = true
        tracker:Refresh()
        Line(UQ.L("CMD_TRACKER_RESET_DONE"))
        return
    elseif command == "objectives" then
        local mode = string.lower(value)
        if mode ~= "all" and mode ~= "tracked" and mode ~= "none" then
            Line(UQ.L("CMD_TRACKER_OBJECTIVES_USAGE"))
            return
        end
        config:Set("trackerShowObjectives", mode)
        tracker.dirty = true
        tracker:Refresh()
        Line(UQ.L("CMD_TRACKER_OBJECTIVES_SET", mode))
        return
    elseif command == "zones" then
        local grouped = not (config:Get("trackerGroupByZone") and true or false)
        config:Set("trackerGroupByZone", grouped)
        tracker.dirty = true
        tracker:Refresh()
        Line(UQ.L("CMD_TRACKER_ZONES_SET",
            grouped and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF")))
        return
    elseif command == "recent" then
        local lift = not (config:Get("trackerRecentFirst") and true or false)
        config:Set("trackerRecentFirst", lift)
        tracker.dirty = true
        tracker:Refresh()
        Line(UQ.L("CMD_TRACKER_RECENT_SET",
            lift and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF")))
        return
    elseif command == "native" then
        local hide = not (config:Get("trackerHideNativeWatch") and true or false)
        config:Set("trackerHideNativeWatch", hide)
        tracker:ApplyNativeWatchVisibility()
        if hide then
            Line(UQ.L("CMD_TRACKER_NATIVE_HIDDEN"))
            Line("  |cff888888" .. UQ.L("CMD_TRACKER_NATIVE_TIMER_NOTE") .. "|r")
        else
            Line(UQ.L("CMD_TRACKER_NATIVE_SHOWN"))
        end
        return
    elseif command == "width" then
        local width = tonumber(value)
        if not width or width < 110 or width > 600 then
            Line(UQ.L("CMD_TRACKER_WIDTH_USAGE"))
            return
        end
        config:Set("trackerWidth", width)
        tracker.dirty = true
        tracker:Refresh()
        Line(UQ.L("CMD_TRACKER_WIDTH_SET", tostring(width)))
        return
    elseif command == "height" then
        local height = tonumber(value)
        if not height or (height ~= 0 and (height < 60 or height > 900)) then
            Line(UQ.L("CMD_TRACKER_HEIGHT_USAGE"))
            return
        end
        config:Set("trackerHeight", height)
        tracker.dirty = true
        tracker:Refresh()
        if height == 0 then
            Line(UQ.L("CMD_TRACKER_HEIGHT_NONE"))
        else
            Line(UQ.L("CMD_TRACKER_HEIGHT_SET", tostring(height)))
        end
        return
    elseif command == "unfold" then
        config:ClearSection("trackerCollapsedQuests")
        config:ClearSection("trackerCollapsedZones")
        config:Set("trackerCollapsed", false)
        tracker.dirty = true
        tracker:Refresh()
        Line(UQ.L("CMD_TRACKER_UNFOLD_DONE"))
        return
    elseif command == "unhideall" then
        config:ClearSection("trackerHiddenQuests")
        tracker.dirty = true
        tracker:Refresh()
        Line(UQ.L("CMD_TRACKER_UNHIDEALL_DONE"))
        return
    elseif command ~= "" then
        Line(UQ.L("CMD_TRACKER_UNKNOWN", command))
    end

    local report = tracker:GetReport()
    Line(UQ.L("CMD_TRACKER_TITLE"))
    if not report.created then
        Line("  |cffff5555" .. UQ.L("CMD_TRACKER_NOT_CREATED") .. "|r")
        return
    end
    Line("  " .. (report.enabled and UQ.L("CMD_TRACKER_STATE_SHOWN")
            or UQ.L("CMD_TRACKER_STATE_HIDDEN"))
        .. (report.collapsed and (", " .. UQ.L("CMD_TRACKER_STATE_FOLDED")) or "")
        .. " -- " .. UQ.LN("CMD_TRACKER_ROWS", report.lines))
    local height = report.height
    if type(height) ~= "number" or height <= 0 then
        height = UQ.L("CMD_TRACKER_HEIGHT_AUTO")
    else
        height = UQ.L("CMD_TRACKER_HEIGHT_MAX", string.format("%.0f", height))
    end
    Line("  width=" .. tostring(report.width) .. " height=" .. tostring(height)
        .. " objectives=" .. tostring(report.objectives)
        .. " zones=" .. (report.groupByZone and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF"))
        .. " curzone=" .. (report.currentZoneOnly and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF"))
        .. " recent=" .. (report.recentFirst and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF"))
        -- Diagnostic tokens, deliberately untranslated: the zone the filter
        -- settled on, which of MapContext:GetStandingZone's routes produced it
        -- (standing / standingSpan / parent / remembered / mapZone /
        -- unlistable), the area the map half is asking about, how many quests
        -- it kept whose quest-log header names another zone, and the two ways
        -- the filter can hide everything (Quest/TrackerFrame.lua, "The filter
        -- may narrow the window, never empty it"). zonedrop=true means the
        -- zone the addon settled on could not be identified and the filter was
        -- abandoned for that build; zoneempty=true means it was identified and
        -- the player simply has nothing to do here.
        .. (report.currentZoneOnly and (" zone=" .. tostring(report.currentZoneName)
            .. " via=" .. tostring(report.currentZoneHow)
            .. " area=" .. tostring(report.currentZoneArea)
            .. " mapkept=" .. tostring(report.mapKept)
            .. " zonedrop=" .. tostring(report.zoneFilterDropped)
            .. " zoneempty=" .. tostring(report.zoneFilterEmpty)) or "")
        .. " unstarted=" .. (report.hideUnstarted and UQ.L("COMMON_ON") or UQ.L("COMMON_OFF")))
    Line("  " .. UQ.L("CMD_TRACKER_POSITION", tostring(report.point),
        string.format("%.0f, %.0f", report.x or 0, report.y or 0))
        .. " -- drags=" .. tostring(report.drags)
        .. " failures=" .. tostring(report.dragFailures)
        .. " resizes=" .. tostring(report.resizes))
    Line("  redraws=" .. tostring(report.redraws) .. " row clicks=" .. tostring(report.clicks))
    Line("  " .. (report.hideNativeWatch and UQ.L("CMD_TRACKER_NATIVE_HIDDEN")
        or UQ.L("CMD_TRACKER_NATIVE_SHOWN")))
    if report.dragFailures > 0 then
        Line("  |cffff5555" .. UQ.L("CMD_TRACKER_DRAG_REFUSED") .. "|r")
    end
end

-- Main quest -----------------------------------------------------------------

-- Both /uq main and /uq waypoint drive the gated layer. When the gate is off
-- their modules still exist and still answer, but they have registered nothing,
-- so every counter reads zero and every report reads like a broken feature.
-- Say what is actually happening instead.
local function FeatureDisabledNotice()
    Line(UQ.L("CMD_FEATURE_DISABLED_TITLE",
        "|cffff5555" .. UQ.L("CMD_STATE_DISABLED") .. "|r"))
    Line("  " .. UQ.L("CMD_FEATURE_DISABLED_1"))
    Line("  " .. UQ.L("CMD_FEATURE_DISABLED_2"))
    Line("  " .. UQ.L("CMD_FEATURE_DISABLED_3"))
end

local function ShowMainQuest()
    local mainQuest = UQ:GetModule("MainQuest")
    local clicks = UQ:GetModule("QuestClicks")
    if not mainQuest then
        Line(UQ.L("CMD_MODULE_MISSING_MAINQUEST"))
        return
    end

    local report = mainQuest:GetReport()
    if not report.titleKey then
        Line(UQ.L("CMD_MAIN_NOT_FOLLOWING"))
        Line("  " .. UQ.L("CMD_MAIN_HOW_TO_FOLLOW"))
    else
        Line(UQ.L("CMD_MAIN_FOLLOWING", "|cff" .. UQ.colors.accentHex
            .. tostring(report.title or report.titleKey) .. "|r"))
        if report.title then
            Line("  " .. UQ.L("CMD_MAIN_DETAIL", tostring(report.index),
                tostring(report.level), tostring(report.matchConfidence)))
            if report.isComplete == 1 then
                Line("  " .. UQ.L("CMD_MAIN_READY_TO_HAND_IN"))
            end
        else
            Line("  |cffff5555" .. UQ.L("CMD_MAIN_NOT_IN_LOG") .. "|r "
                .. UQ.L("CMD_MAIN_REMEMBERED_AS", tostring(report.titleKey)))
        end
    end
    Line("  restored=" .. tostring(report.restored)
        .. " selections=" .. tostring(report.selections))

    -- Quest-log selection is intentionally native-only; its Following button
    -- calls the selection module directly. These counters diagnose only the
    -- addon-owned surfaces over native tracker FontStrings.
    if clicks then
        local click = clicks:GetReport()
        Line("  " .. UQ.L("CMD_MAIN_CLICK_SURFACES",
            tostring(click.watchLinesMapped)))
        Line("  " .. UQ.L("CMD_MAIN_CLICKS_SEEN",
            tostring(click.watchClicks), tostring(click.modifier)))
    end
end

local function ChangeMainQuest(target)
    local mainQuest = UQ:GetModule("MainQuest")
    if not mainQuest then
        Line(UQ.L("CMD_MODULE_MISSING_MAINQUEST"))
        return
    end

    local trimmed = UQ.Trim(target) or ""
    if trimmed == "" then
        ShowMainQuest()
        return
    end
    if string.lower(trimmed) == "clear" or string.lower(trimmed) == "none" then
        mainQuest:ReturnToAutomatic()
        local navigator = UQ:GetModule("Navigator")
        if navigator then
            navigator:Refresh()
        end
        local trackerFrame = UQ:GetModule("TrackerFrame")
        if trackerFrame then
            trackerFrame.dirty = true
            trackerFrame:Refresh()
        end
        ShowMainQuest()
        return
    end

    local titleKey, questOrReason, titles = mainQuest:ResolveTarget(trimmed)
    if not titleKey then
        if questOrReason == "ambiguous" then
            Line(UQ.L("CMD_MAIN_AMBIGUOUS", trimmed))
            local index = 1
            local total = table.getn(titles or {})
            while index <= total do
                Line("  " .. titles[index])
                index = index + 1
            end
        elseif questOrReason == "noQuestAtIndex" then
            Line(UQ.L("CMD_MAIN_NO_INDEX", trimmed))
        else
            Line(UQ.L("CMD_MAIN_NO_MATCH", trimmed))
        end
        return
    end

    mainQuest:Set(titleKey)
    Line(UQ.L("CMD_MAIN_FOLLOWING", "|cff" .. UQ.colors.accentHex
        .. tostring(questOrReason.title) .. "|r"))
end

-- Waypoint --------------------------------------------------------------------

local function ShowNavigator()
    local navigator = UQ:GetModule("Navigator")
    if not navigator then
        Line(UQ.L("CMD_MODULE_MISSING_WAYPOINT"))
        return
    end

    navigator:ShowDebugMapTarget()
    local report = navigator:GetReport()
    Line(UQ.L("CMD_NAV_TITLE"))
    Line("  enabled=" .. tostring(report.enabled)
        .. " created=" .. tostring(report.created)
        .. " shown=" .. tostring(report.shown))
    Line("  placements=" .. tostring(report.placements)
        .. " failures=" .. tostring(report.placementFailures)
        .. " rotations=" .. tostring(report.rotations)
        .. "/" .. tostring(report.rotationFailures))

    -- The one line that separates "the arrow is wrong" from "the arrow cannot
    -- exist on this client": the rotated texture quad is documented, not
    -- probed, so its answer is worth printing rather than assuming.
    if report.rotationSupported == false then
        Line("  |cffff5555" .. UQ.L("CMD_NAV_NO_ROTATION") .. "|r")
    end

    if report.shown then
        local yards = report.distanceYards
        local degrees = report.relativeAngle
            and string.format("%.0f", report.relativeAngle * 180 / math.pi)
            or "-"
        Line("  distance=" .. (yards and string.format("%.0f", yards) or "?")
            .. "yd relative=" .. degrees .. "deg"
            .. " facing=" .. tostring(report.facingSource or "none")
            .. " target=" .. tostring(report.targetKind or "none")
            .. " quest=" .. tostring(report.targetTitle or "none"))
    elseif report.hiddenReason then
        Line("  " .. UQ.L("CMD_NAV_HIDDEN", tostring(report.hiddenReason)))
    end
    if report.targetX and report.targetY then
        Line("  origin=" .. tostring(report.targetAreaId) .. ":"
            .. string.format("%.2f,%.2f", report.targetX, report.targetY)
            .. " mapMark=" .. tostring(report.debugMapShown))
    end

    local counts = report.hiddenCounts or {}
    local reason, count
    local any = false
    for reason, count in pairs(counts) do
        if not any then
            Line("  " .. UQ.L("CMD_NAV_HIDDEN_REASONS"))
            any = true
        end
        Line("    " .. tostring(reason) .. " x" .. tostring(count))
    end
end

local function ShowWaypoint(target)
    local waypoint = UQ:GetModule("Waypoint")
    local heading = UQ:GetModule("PlayerHeading")
    if not waypoint then
        Line(UQ.L("CMD_MODULE_MISSING_WAYPOINT"))
        return
    end

    -- `/uq waypoint recalibrate` throws away a settled facing convention and
    -- re-runs the vote. The only reason to need it is a marker that points
    -- consistently wrong, which means the vote settled on the wrong cell --
    -- possible if the player spent the whole measurement backpedalling.
    if target == "recalibrate" and heading then
        heading:ResetConvention()
    end

    local report = waypoint:GetReport()
    Line(UQ.L("CMD_WAYPOINT_TITLE"))
    Line("  enabled=" .. tostring(report.enabled)
        .. " created=" .. tostring(report.created)
        .. " shown=" .. tostring(report.shown))
    Line("  placements=" .. tostring(report.placements)
        .. " failures=" .. tostring(report.placementFailures))

    if report.shown then
        local yards = report.distanceYards
        Line("  " .. UQ.L("CMD_WAYPOINT_DISTANCE",
            (yards and string.format("%.0f", yards) or "?"),
            tostring(report.clamped), tostring(report.areaId)))
    elseif report.hiddenReason then
        Line("  " .. UQ.L("CMD_WAYPOINT_HIDDEN", tostring(report.hiddenReason)))
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
            Line("  " .. UQ.L("CMD_WAYPOINT_HIDDEN_REASONS"))
            any = true
        end
        Line("    " .. tostring(reason) .. " x" .. tostring(count))
    end

    if heading then
        local headingReport = heading:GetReport()
        Line("  " .. UQ.L("CMD_WAYPOINT_FACING",
            (headingReport.facing and string.format("%.2f rad", headingReport.facing)
                or UQ.L("COMMON_NONE")),
            tostring(headingReport.source or UQ.L("COMMON_NOTHING")))
            .. (headingReport.stale and (" " .. UQ.L("CMD_WAYPOINT_STALE")) or ""))
        Line("  " .. UQ.L("CMD_WAYPOINT_HEADING_COUNTS", tostring(headingReport.samples),
            tostring(headingReport.movementFixes),
            tostring(headingReport.clientSource or UQ.L("COMMON_NONE"))))

        -- Untranslated on purpose, like the enabled=/created= line above: this
        -- is a measurement to be pasted into the compatibility database, not
        -- prose. It is the readout that tells a marker aimed the wrong way
        -- apart from one aimed at the wrong target -- `raw` is what the client
        -- returned, `facing` above is what it became.
        if headingReport.clientSource then
            Line("  convention=" .. tostring(heading:ConventionLabel())
                .. " votes=" .. tostring(headingReport.conventionSamples)
                .. " raw=" .. (headingReport.rawFacing
                    and string.format("%.2f", headingReport.rawFacing) or "nil"))
        end
        if not headingReport.facing then
            Line("  |cffff5555" .. UQ.L("CMD_WAYPOINT_NO_FACING_SOURCE") .. "|r -- "
                .. UQ.L("CMD_WAYPOINT_NO_FACING_HINT"))
        end
    end
end

-- Diagnostic only: no probe covers QuestLogFrame's real child/region layout
-- on this client (query_compat.py has nothing but generic Vanilla API docs
-- for it), so this walks it live and prints what is actually there. Used to
-- find a real anchor for the quest-log Show/Track buttons.
local function DumpFrame(label, frame, depth)
    if not frame then
        Line(label .. ": " .. UQ.L("COMMON_NOT_FOUND"))
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
        Line(UQ.L("CMD_QUESTLOG_DUMP_USAGE"))
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
        Line(UQ.L("CMD_MODULE_MISSING_SETTINGS"))
        return
    end

    if target == "button" or target == "button on" or target == "button off" then
        local report = settings:GetReport()
        if report.host == "unrealui" then
            Line(UQ.L("CMD_CONFIG_UNREALUI_BUTTON"))
            return
        end
        local enabled = nil
        if target == "button on" then
            enabled = true
        elseif target == "button off" then
            enabled = false
        end
        if settings:SetMinimapButtonEnabled(enabled) then
            Line(UQ.L("CMD_CONFIG_BUTTON_SHOWN",
                tostring(settings:GetReport().minimapAnchor)))
        else
            Line(UQ.L("CMD_CONFIG_BUTTON_HIDDEN"))
        end
        return
    end

    if not settings:Toggle() then
        local report = settings:GetReport()
        if report.host ~= "unrealui" then
            Line(UQ.L("CMD_CONFIG_WINDOW_FAILED"))
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
    elseif command == "nav" or command == "navigator" then
        if UQ:IsFeatureEnabled("mainQuestWaypoint") then
            ShowNavigator()
        else
            FeatureDisabledNotice()
        end
    elseif command == "waypoint" then
        if UQ:IsFeatureEnabled("mainQuestWaypoint")
            and UQ:IsFeatureEnabled("hudWorldMarker") then
            ShowWaypoint(UQ.Trim(target) or "")
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
    elseif command == "rare" or command == "rares" then
        ShowRareAlert(target)
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
            Line(UQ.L("CMD_DEBUG_ENABLED"))
        else
            Line(UQ.L("CMD_DEBUG_DISABLED"))
        end
    else
        Line(UQ.L("CMD_UNKNOWN", command))
        ShowHelp()
    end
end

function Commands:OnInit()
    SLASH_UNREALQUEST1 = "/uq"
    SLASH_UNREALQUEST2 = "/unrealquest"
    SlashCmdList.UNREALQUEST = Handler
end
