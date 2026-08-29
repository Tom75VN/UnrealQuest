--[[
UnrealQuest / Core/Settings.lua

The options page, and which window draws it.

Two hosts, ONE builder. If unrealUI is installed, UnrealQuest registers its page
with unrealUI's settings window and the player finds it in the same place as
every other unrealUI option. If it is not, UnrealQuest builds its own window and
hands the SAME builder its own content frame. There is no second layout to keep
in step, and neither addon depends on the other:

  * unrealUI contains no reference to UnrealQuest of any kind. Its settings API
    is push-only -- U.RegisterSettingsTab stores an id, a label and a build
    function and calls it later -- so integrating costs unrealUI nothing and
    needs no change there.
  * UnrealQuest declares no dependency on unrealUI, calls into it only through
    functions it has checked for by type, and falls back to its own window at
    every step where the integration could fail.

Detection is a POLL, not a load-order assumption or an event:
  * UnrealQuest.toc declares no dependency, and the client's TOC dependency
    fields have no record in the compatibility database at all -- so nothing
    establishes that unrealUI's files run before this one.
  * IsAddOnLoaded is DOCUMENTED_NOT_RUNTIME_VERIFIED here, and in any case it
    answers "the files were loaded", not "the settings API exists". The page is
    registered against the API it actually needs, found by type check.
  * ADDON_LOADED has no probed record on this client either, so no event may be
    the mechanism (Core/Driver.lua's rule).

The host is decided ONCE, within a bounded window after the player is in the
world, and never changes afterwards. A host that could flip mid-session would
mean a page whose regions are parented to a window that is no longer the one on
screen.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Settings = UQ:NewModule("Settings")

-- The id unrealUI files the page under. Checked against unrealUI's own ids
-- ("general", "unitframes", "petbar", "actionbars.*") so registration cannot
-- collide with a page it already owns.
local TAB_ID = "unrealquest"
local TAB_LABEL = "UnrealQuest"

-- The page's own first line: "Unreal Quest" in the addon's two-tone wordmark,
-- with the running version after it. The split is the one the TOC Title already
-- uses -- "Unreal" white, "Quest" in the shared accent -- so the options page
-- names the addon the way the addon list does. unrealUI's menu row stays the
-- plain TAB_LABEL because that host draws it in a sidebar of its own rows; the
-- standalone window has no such row and titles its header with this wordmark
-- instead (see BuildWindow).
--
-- Inline colour escapes rather than SetTextColor, because one region has to
-- carry three colours where a heading region has one. Every span is closed, so
-- nothing runs on into the heading's own accent colour -- including the
-- version, kept grey so it reads as a subscript of the name rather than part
-- of it.
--
-- Built on call, not at file scope: a file-scope copy would freeze a version
-- read before Core/Namespace.lua had necessarily run. UQ.version is the single
-- place the number is written down in Lua.
local function PageTitle()
    return "|cffffffffUnreal |cff" .. UQ.colors.accentHex .. "Quest|r"
        .. " |cff888888v" .. tostring(UQ.version) .. "|r"
end

-- No hyphens, ever: the client mangles a widget name containing one.
local WINDOW_NAME = "UnrealQuestSettings"
local HANDLE_NAME = "UnrealQuestSettingsHandle"
local CONTENT_NAME = "UnrealQuestSettingsContent"
local CLOSE_NAME = "UnrealQuestSettingsClose"
local MINIMAP_BUTTON_NAME = "UnrealQuestMinimapButton"

-- Sized so the content box the page is handed matches the one unrealUI's panel
-- hands it. Both come out of Client.GetSettingsMetrics rather than being
-- written down twice.
local CONTENT_WIDTH = 496
local CONTENT_HEIGHT = 428
-- Text stops short of the content edge so future copy and localization cannot
-- escape the panel, the same margin unrealUI keeps on its own settings text.
local TEXT_WIDTH = CONTENT_WIDTH - 12

local HOST_POLL_INTERVAL = 0.5
-- How long to keep looking for unrealUI before committing to our own window.
-- Generous on purpose: this is a once-per-session decision and the job costs
-- one global read every half second until it is made.
local HOST_POLL_SECONDS = 15

Settings.host = nil           -- nil while undecided, then "unrealui" or "standalone"
Settings.hostWaited = 0
Settings.window = nil
Settings.handle = nil
Settings.content = nil
Settings.close = nil
-- The standalone host's built page: { widgets = { ... }, refresh = fn }.
-- unrealUI owns the lifecycle of its own copy and this stays nil there.
Settings.page = nil
Settings.opens = 0
Settings.dragFailures = 0
Settings.liveSliders = {}
-- The settings button beside the minimap, and what it ended up anchored to.
-- Built straight away while the host poll runs so a standalone install never
-- makes the player wait through the full late-unrealUI grace period. If
-- unrealUI is found, its own identical button takes over and this one hides.
Settings.minimapButton = nil
Settings.minimapAnchor = nil
-- The language flags in the standalone window's header, and nothing at all in
-- the unrealUI host: see BuildLanguageSelector.
Settings.languageButtons = {}

local function Config()
    return UQ:GetModule("Config")
end

local function Setting(key)
    local config = Config()
    if not config then
        return nil
    end
    return config:Get(key)
end

local function Store(key, value)
    local config = Config()
    if config then
        config:Set(key, value)
    end
end

-- unrealUI's namespace, but only if it carries the one function this needs.
-- Deliberately NOT IsAddOnLoaded: a loaded addon whose settings module failed
-- would pass that test and then refuse the page.
local function UnrealUI()
    local host = Client.GetNamedObject("UnrealUI")
    if not host or type(host.RegisterSettingsTab) ~= "function" then
        return nil
    end
    return host
end

-- Page layout ---------------------------------------------------------------
--
-- ADDING A CHECKBOX OR RADIO IS TWO LINES, AND NEITHER IS ABOUT THE HOST:
--
--   1. its default in Core/Config.lua
--   2. one `page.Checkbox(...)` call in BuildPage below
--
-- A continuous value uses page.Slider and supplies its live apply callback.
-- There is no offset to recompute, no widget name
-- to invent, no refresh function to extend, and nothing to add for the second
-- window -- unrealUI and the standalone window both call this same builder, so
-- an option added here appears in whichever one is hosting the page, this
-- session and every session after.
--
-- The cursor is what buys that. Each Add* call places its region at the running
-- Y, advances it by what the region actually occupies, files the region in the
-- page's widget list (so both hosts show and hide it), and -- for a bound
-- control -- files a sync closure the page's refresh runs on every open (so the
-- control always opens on the stored value, never on a build-time snapshot).

local HEADING_ADVANCE = 22
local BODY_LINE_HEIGHT = 13
local CHECKBOX_ADVANCE = 18
local SLIDER_ADVANCE = 58
local RULE_ADVANCE = 16
local BUTTON_WIDTH = 150
local BUTTON_HEIGHT = 20
local BUTTON_ADVANCE = BUTTON_HEIGHT + 8
local ROW_GAP = 8
local NOTE_INDENT = 20

-- Average glyph width for the small font, used ONLY when the client will not
-- report a laid-out FontString's height. Deliberately narrow, so the estimate
-- errs towards more lines and controls crowd rather than overlap.
local ESTIMATED_GLYPH_WIDTH = 5.6

local function TextHeight(region, text, width)
    local measured = Client.GetObjectHeight(region)
    if type(measured) == "number" and measured > 0 then
        return measured
    end
    local perLine = math.floor(width / ESTIMATED_GLYPH_WIDTH)
    if perLine < 1 then
        perLine = 1
    end
    local lines = math.ceil(string.len(text or "") / perLine)
    if lines < 1 then
        lines = 1
    end
    return lines * BODY_LINE_HEIGHT
end

-- Widget names are derived from the setting key so a new option cannot collide
-- with an existing one or pick up a hyphen (which this client mangles). Only
-- the first byte is folded, by hand in the ASCII range: string.upper is
-- locale-dependent here and corrupts multi-byte text, and while a config key is
-- always ASCII, the addon does not keep two rules for the same job.
local function WidgetName(key)
    local first = string.byte(key, 1)
    if first and first >= 97 and first <= 122 then
        return "UnrealQuestSettings" .. string.char(first - 32) .. string.sub(key, 2)
    end
    return "UnrealQuestSettings" .. key
end

local function NewPage(parent)
    local page = { parent = parent, widgets = {}, syncs = {}, y = 0 }

    page.Add = function(region)
        if region then
            table.insert(page.widgets, region)
        end
        return region
    end

    -- Registers a closure the page runs every time it is opened.
    page.Sync = function(callback)
        if type(callback) == "function" then
            table.insert(page.syncs, callback)
        end
    end

    page.Gap = function(pixels)
        page.y = page.y - (pixels or ROW_GAP)
    end

    -- `marginTop` moves one title down inside its existing reserved band. The
    -- page is already at the fixed height shared by both non-scrolling hosts,
    -- so this creates visual separation without growing the complete page.
    page.Heading = function(text, marginTop)
        local inset = type(marginTop) == "number" and marginTop or 0
        if inset < 0 then
            inset = 0
        elseif inset > HEADING_ADVANCE then
            inset = HEADING_ADVANCE
        end
        local region = page.Add(Client.CreateSettingsHeading(page.parent, text,
            0, page.y - inset))
        page.y = page.y - HEADING_ADVANCE
        return region
    end

    -- `reservedLines`, when given, fixes how much vertical space the line
    -- takes instead of measuring the text placed in it. Needed by any line
    -- whose text is rewritten at runtime (Client.SetSettingsBodyText): the
    -- cursor placed everything below it at build time from the height of the
    -- placeholder, so a longer replacement would otherwise run into the next
    -- control. Reserving the worst case up front is what keeps the layout
    -- honest -- the caller is then responsible for keeping its text inside it.
    page.Body = function(text, indent, reservedLines)
        indent = indent or 0
        local width = TEXT_WIDTH - indent
        local region = page.Add(Client.CreateSettingsBody(page.parent, text,
            indent, page.y, width))
        local height
        if type(reservedLines) == "number" and reservedLines > 0 then
            height = reservedLines * BODY_LINE_HEIGHT
        else
            height = TextHeight(region, text, width)
        end
        page.y = page.y - height - 4
        return region
    end

    page.Rule = function()
        local region = page.Add(Client.CreateSettingsRule(page.parent, 0, page.y, TEXT_WIDTH))
        page.y = page.y - RULE_ADVANCE
        return region
    end

    -- One option. `key` is both the stored setting and the source of the widget
    -- name; `note` is the optional grey line under it.
    --
    -- `layout` is the same optional table page.Slider takes, and is there for
    -- the same reason: a control that shares a row with the one before it. The
    -- earlier control passes `advance = 0` so the cursor stays on its line, and
    -- this one is placed at `left` and given the width that is left over. The
    -- fixed 428px content box is what makes it worth having -- a paired option
    -- costs the page nothing vertically. Only pair a NOTELESS checkbox with a
    -- taller control (a slider's 58px band), so no locale's wrapped text can
    -- outgrow the row and run into whatever is drawn below it.
    page.Checkbox = function(key, text, note, layout)
        layout = layout or {}
        local left = type(layout.left) == "number" and layout.left or 0
        local width = type(layout.width) == "number" and layout.width
            or (TEXT_WIDTH - NOTE_INDENT - left)
        local box = Client.CreateSettingsCheckbox(page.parent, WidgetName(key), text,
            left, page.y, width,
            function(checked)
                Store(key, checked)
            end)
        page.Add(box)
        if type(layout.advance) == "number" then
            page.y = page.y - layout.advance
            page.Sync(function()
                Client.SetSettingsCheckbox(box, Setting(key) and true or false)
            end)
            return box
        end
        page.y = page.y - CHECKBOX_ADVANCE
        if note then
            page.Body(note, NOTE_INDENT)
        end
        page.y = page.y - ROW_GAP
        page.Sync(function()
            Client.SetSettingsCheckbox(box, Setting(key) and true or false)
        end)
        return box
    end

    -- One setting, several mutually exclusive values, drawn as a titled column
    -- of radio rows. Same contract as page.Checkbox and the same two lines to
    -- add one: a default in Core/Config.lua and one call here.
    --
    -- `options` is an array of { value = ..., label = "...", note = "..." }.
    -- The stored value is compared to `value` by equality, so anything the
    -- config store round-trips (a boolean, a number, a short string) works.
    --
    -- The group is what makes these radios rather than checkboxes: selecting
    -- one clears the others, and only this closure knows who the others are.
    -- Nothing here reads the widgets' own state to decide -- the stored setting
    -- is the single source of truth, on the click and on every page open.
    page.Radio = function(key, title, options, note)
        if title then
            page.Body(title)
        end
        local buttons = {}
        local total = table.getn(options)

        local function Select(index)
            local optionIndex = 1
            while optionIndex <= total do
                Client.SetSettingsRadio(buttons[optionIndex], optionIndex == index)
                optionIndex = optionIndex + 1
            end
        end

        local index = 1
        while index <= total do
            local option = options[index]
            -- Captured per row: `index` is the loop variable and the closure
            -- below outlives this iteration.
            local rowIndex = index
            local rowValue = option.value
            local button = Client.CreateSettingsRadio(page.parent,
                WidgetName(key) .. "Option" .. tostring(index),
                option.label, NOTE_INDENT, page.y, TEXT_WIDTH - NOTE_INDENT * 2,
                function()
                    Store(key, rowValue)
                    Select(rowIndex)
                end)
            buttons[index] = button
            page.Add(button)
            page.y = page.y - CHECKBOX_ADVANCE
            if option.note then
                page.Body(option.note, NOTE_INDENT * 2)
            end
            index = index + 1
        end

        if note then
            page.Body(note, NOTE_INDENT)
        end
        page.y = page.y - ROW_GAP

        page.Sync(function()
            local stored = Setting(key)
            local selected = 0
            local syncIndex = 1
            while syncIndex <= total do
                if options[syncIndex].value == stored then
                    selected = syncIndex
                end
                syncIndex = syncIndex + 1
            end
            -- A stored value no option names -- an older build's setting, or a
            -- hand-edited file -- leaves every row clear rather than picking
            -- one for the player and writing that choice back.
            Select(selected)
        end)
        return buttons
    end

    -- An action rather than a setting: it runs something once and stores
    -- nothing, so unlike Checkbox/Radio/Slider it registers no sync closure
    -- and has no value to open on. `key` still names the widget so the same
    -- collision-free, hyphen-free naming rule applies.
    --
    -- The handler is handed the button back, so an action that wants to report
    -- what it did can relabel itself without the page having to hold a
    -- reference for it.
    page.Button = function(key, text, onClick, width)
        -- Declared before the creator call so the click closure can capture it
        -- as an upvalue and hand the button to its own handler.
        local button
        button = Client.CreateSettingsButton(page.parent, WidgetName(key),
            text, 0, page.y, width or BUTTON_WIDTH, BUTTON_HEIGHT,
            function()
                if type(onClick) == "function" then
                    onClick(button)
                end
            end)
        if not button then
            return nil
        end
        page.Add(button)
        page.y = page.y - BUTTON_ADVANCE
        return button
    end

    -- The real unrealUI component is used when that addon hosts this page.
    -- Standalone uses Client.CreateSettingsSlider, the imported equivalent in
    -- the compatibility layer. Both expose the same current/SetPoint/SetValue
    -- surface, so binding and live application stay host-independent.
    page.Slider = function(key, text, minimum, maximum, step, onLive, layout)
        local host = UnrealUI()
        local createSlider = host and type(host.CreateSlider) == "function"
            and host.CreateSlider or Client.CreateSettingsSlider
        if type(createSlider) ~= "function" then
            return nil
        end

        local liveEntry
        local function Apply(value)
            if type(value) ~= "number" then
                return
            end
            if Setting(key) ~= value then
                Store(key, value)
            end
            if liveEntry then
                liveEntry.last = value
            end
            if type(onLive) == "function" then
                onLive(value)
            end
        end

        layout = layout or {}
        local width = type(layout.width) == "number" and layout.width or 260
        local left = type(layout.left) == "number" and layout.left or 0
        local advance = type(layout.advance) == "number" and layout.advance or SLIDER_ADVANCE
        local slider = createSlider(page.parent, {
            name = WidgetName(key),
            text = text,
            width = width,
            min = minimum,
            max = maximum,
            step = step,
            value = Setting(key),
            onChange = Apply,
        })
        if not slider then
            return nil
        end
        slider.SetPoint("TOPLEFT", page.parent, "TOPLEFT", left, page.y - 18)
        page.Add(slider)
        page.y = page.y - advance

        liveEntry = { key = key, control = slider, onLive = onLive,
            last = slider.current }
        table.insert(Settings.liveSliders, liveEntry)
        page.Sync(function()
            local value = Setting(key)
            slider.SetValue(value)
            liveEntry.last = slider.current
        end)
        return slider
    end

    page.Refresh = function()
        local index = 1
        local total = table.getn(page.syncs)
        while index <= total do
            page.syncs[index]()
            index = index + 1
        end
    end

    return page
end

-- The page ------------------------------------------------------------------
--
-- The contract is unrealUI's (modules/settings.lua, RegisterSettingsTab):
-- build(parent) returns the array of regions the page owns, and optionally a
-- refresh function that runs every time the page is opened. The standalone
-- window honours the same contract, so this function never learns which host
-- called it -- it is handed a parent frame and anchors everything to that.
--
-- ONE PAGE, ONE TAB, ALWAYS. Everything UnrealQuest exposes goes in here, under
-- headings. It deliberately does not call RegisterSettingsGroup or register a
-- second tab: a group would scatter the addon's options across several rows of
-- unrealUI's sidebar, and the standalone window has no sidebar to mirror that
-- with -- the two hosts would stop being the same page.

function Settings:BuildPage(parent)
    if not parent then
        return {}, nil
    end

    local page = NewPage(parent)
    self.liveSliders = {}

    -- The page opens on the addon's own name and version (PageTitle) instead of
    -- a section heading, in the heading's place and at the heading's cost -- so
    -- the sections below sit exactly where they did and still fit the fixed
    -- content box shared by the two hosts. The tracker options follow it
    -- directly; they are the first section whether or not it is labelled.
    --
    -- Skipped on the standalone host: that window's own header already carries
    -- this wordmark (BuildWindow), so drawing it again as the first line would
    -- show it twice. unrealUI draws no such title, so under that host this stays
    -- the only place the page names the addon. The tracker section simply
    -- starts one heading higher when it is skipped.
    if self.host ~= "standalone" then
        page.Heading(PageTitle())
    else
        -- No heading to sit under here (the window's own header carries the
        -- wordmark), so the first row would otherwise butt right against the
        -- header rule. A little of the height the skipped heading freed up
        -- goes back as breathing room.
        page.Gap(7)
    end

    -- The tracker opacity and rare-alert range sliders share one row. The
    -- alert switch and two tracker filters use the two compact rows beneath.
    --
    -- The page is within a PIXEL of the fixed 428px content box both hosts
    -- hand it (the smoke test measures it), and neither host scrolls, so a new
    -- heading plus a row of its own would have pushed its own controls off the
    -- bottom -- silently, which is what the height check exists to prevent. A
    -- The sliders need 52px here and the two checkbox rows need 36px. The world
    -- map heading below is enough separation without another 16px rule, keeping
    -- the complete page inside the fixed content box (guarded below and in smoke).
    --
    -- The rare alert is ONE switch on purpose: it covers rares, rare elites
    -- and bosses, and there is no per-rank filtering to expose.
    --
    -- The sound kit remains on "/uq rare" because it has to be AUDITIONED: an
    -- unknown SoundEntries kit name is silent rather than an error here.
    local rowTop = page.y
    page.Slider("trackerBackgroundOpacity", UQ.L("SETTINGS_TRACKER_OPACITY"), 0, 100, 1,
        function(value)
            local tracker = UQ:GetModule("TrackerFrame")
            if tracker then
                tracker:ApplyBackgroundOpacity(value)
            end
        end, { width = 160, advance = 0 })
    page.y = rowTop
    page.Slider("rareAlertRange", UQ.L("SETTINGS_RARE_ALERT_RANGE"), 20, 500, 1,
        nil, { left = 250, width = 160, advance = 52 })

    page.Checkbox("rareAlert", UQ.L("SETTINGS_RARE_ALERT"),
        nil, { width = 230, advance = 0 })
    page.Checkbox("trackerCurrentZoneOnly", UQ.L("SETTINGS_TRACKER_CURRENT_ZONE"),
        nil, { left = 250, width = TEXT_WIDTH - 250, advance = CHECKBOX_ADVANCE })
    local row2Top = page.y
    page.Checkbox("trackerHideUnstartedQuests", UQ.L("SETTINGS_TRACKER_HIDE_UNSTARTED"),
        nil, { width = 230, advance = 0 })
    page.y = row2Top
    page.Checkbox("trackerProgressBar", UQ.L("SETTINGS_TRACKER_PROGRESS_BAR"),
        nil, { left = 250, width = TEXT_WIDTH - 250, advance = CHECKBOX_ADVANCE })

    page.Heading(UQ.L("SETTINGS_HEADING_WORLD_MAP"), 7)

    -- Two presentations of one scene, and neither is the absence of the other,
    -- so the choice is a radio rather than a checkbox naming one of them.
    -- Map/WorldMapPins.lua carries the setting into its view signature, so
    -- picking a row repaints the map on the next refresh with nothing here to
    -- notify.
    page.Radio("mapObjectiveDots", UQ.L("SETTINGS_MAP_OBJECTIVE_STYLE"), {
        { value = true, label = UQ.L("SETTINGS_MAP_STYLE_DOTS"),
          note = UQ.L("SETTINGS_MAP_STYLE_DOTS_NOTE") },
        { value = false, label = UQ.L("SETTINGS_MAP_STYLE_AREAS"),
          note = UQ.L("SETTINGS_MAP_STYLE_AREAS_NOTE") },
    })

    page.Slider("mapObjectiveDotScale", UQ.L("SETTINGS_MAP_DOT_SIZE"), 50, 150, 1,
        function()
            local worldMapPins = UQ:GetModule("WorldMapPins")
            if worldMapPins then
                worldMapPins:ApplyObjectiveDotSize()
            end
        end, { width = 160, advance = 0 })

    page.Slider("minimapObjectiveDotScale", UQ.L("SETTINGS_MINIMAP_DOT_SIZE"), 50, 150, 1,
        function()
            local minimapPins = UQ:GetModule("MinimapPins")
            if minimapPins then
                minimapPins:ApplyObjectiveDotSize()
            end
        end, { left = 250, width = 160 })

    -- Notes on this page are kept to one line: both hosts hand the page a
    -- fixed 428px box that neither of them scrolls.
    -- The two short quest options share one line. Their four translations are
    -- deliberately kept within their half-width columns, preserving the page
    -- height in both fixed, non-scrolling hosts.
    page.Checkbox("mapClusterTooltips", UQ.L("SETTINGS_MAP_CLUSTER"), nil,
        { advance = CHECKBOX_ADVANCE })
    page.Checkbox("translateQuestTitles", UQ.L("SETTINGS_TRANSLATE_QUEST_TITLES"), nil,
        { width = 230, advance = 0 })
    page.Checkbox("showLowLevelQuests", UQ.L("SETTINGS_LOW_LEVEL_QUESTS"), nil,
        { left = 250, width = TEXT_WIDTH - 250, advance = CHECKBOX_ADVANCE })

    page.Checkbox("minimapPinsClampEdge", UQ.L("SETTINGS_MINIMAP_CLAMP"),
        UQ.L("SETTINGS_MINIMAP_CLAMP_NOTE"))

    -- The import button's label describes its action. The ordinary row gap
    -- above is enough separation; the old extra 8px is now used by the clearer
    -- two-line rare-alert description at the top of the page.
    page.Heading(UQ.L("SETTINGS_HEADING_QUEST_HISTORY"))

    -- This client has no completed-quest API, so a fresh install cannot know
    -- which quests the character already finished -- see Quest/QuestHistory.lua.
    -- pfQuest kept that record, and where it is loaded it can be copied in.
    -- The status line is rewritten on every page open and after every press,
    -- so the number the player reads is the number the button would act on.
    -- ONE line reserved, because this one is rewritten at runtime and the
    -- cursor cannot re-measure it. DescribeShort() is written to fit that, and
    -- the page is close enough to the bottom of the content box that a
    -- three-line paragraph here pushed the button off it. The breakdown lives
    -- in `/uq pfquest`.
    local importStatus = page.Body(UQ.L("SETTINGS_PFQUEST_CHECKING"), 0, 1)

    local importButton

    local function RefreshImportStatus()
        local importer = UQ:GetModule("PfQuestImport")
        if not importer then
            return
        end
        Client.SetSettingsBodyText(importStatus, importer:DescribeShort())
        Client.SetButtonLabel(importButton, importer:GetButtonLabel())
    end

    -- One button, three jobs, because from the player's side they are one
    -- thing: "get my finished quests in". Which of the three it does depends on
    -- what pfQuest is doing right now, and its label says which -- see
    -- PfQuestImport:GetButtonLabel and :Press.
    importButton = page.Button("pfQuestImport", UQ.L("PFQUEST_BUTTON_IMPORT"), function()
        local importer = UQ:GetModule("PfQuestImport")
        if not importer then
            return
        end
        importer:Press()
        RefreshImportStatus()
    end)

    page.Sync(RefreshImportStatus)

    -- Both hosts hand the page the same fixed content box and neither scrolls
    -- it, so a page that outgrows the box draws its last controls off the
    -- bottom -- silently. Said out loud the moment it happens instead.
    self.pageHeight = -page.y
    if self.pageHeight > CONTENT_HEIGHT then
        UQ:Warn(UQ.L("SETTINGS_WARN_PAGE_TOO_TALL",
            math.floor(self.pageHeight), CONTENT_HEIGHT))
    end

    return page.widgets, page.Refresh
end

-- unrealUI updates its slider's `current` value from its own shared driver;
-- the standalone import exposes RefreshDrag for the same purpose. Comparing
-- that live display value here makes the setting and tracker texture follow
-- the thumb continuously, while the drag is still in progress.
function Settings:RefreshLiveSliders()
    local index = 1
    local total = table.getn(self.liveSliders)
    while index <= total do
        local entry = self.liveSliders[index]
        local control = entry.control
        if control and type(control.RefreshDrag) == "function" then
            control.RefreshDrag()
        end
        local value = control and control.current
        if type(value) == "number" and value ~= entry.last then
            entry.last = value
            Store(entry.key, value)
            if type(entry.onLive) == "function" then
                entry.onLive(value)
            end
        end
        index = index + 1
    end
end

-- Host resolution -----------------------------------------------------------

-- One tab, once. Every UnrealQuest option lives on the page this registers, so
-- there is never a second call to make -- and the guard means a re-entered
-- resolution cannot file a duplicate id and get itself refused.
function Settings:RegisterWithUnrealUI(host)
    if self.registered then
        return true
    end
    local ok, entry = pcall(host.RegisterSettingsTab, TAB_ID, TAB_LABEL,
        function(content)
            return Settings:BuildPage(content)
        end)
    if not ok or not entry then
        return false
    end
    return true
end

-- Decides the host, once. `force` is what ends the search: without it, an absent
-- unrealUI leaves the decision open so the poll can try again.
--
-- unrealUI being PRESENT ends the search either way -- if it is there and still
-- refuses the page, retrying would only repeat its own error output every half
-- second.
function Settings:ResolveHost(force)
    if self.host then
        return self.host
    end

    local host = UnrealUI()
    if host then
        if self:RegisterWithUnrealUI(host) then
            self.host = "unrealui"
            if self.minimapButton then
                Client.HideObject(self.minimapButton)
            end
            UQ:DeclareCapability("unrealUISettingsHost", "detected",
                "unrealUI was found at runtime and accepted UnrealQuest's options page "
                .. "(U.RegisterSettingsTab, id '" .. TAB_ID .. "'). The page is drawn inside "
                .. "unrealUI's settings window; /uq config opens it there. Detected by type-checking "
                .. "the function this needs, not by IsAddOnLoaded, which is "
                .. "DOCUMENTED_NOT_RUNTIME_VERIFIED here and would only report that files loaded")
        else
            self.host = "standalone"
            UQ:DeclareCapability("unrealUISettingsHost", "missing",
                "unrealUI is present but refused the options page -- a page already registered under "
                .. "the id '" .. TAB_ID .. "' is the only documented reason. UnrealQuest's own "
                .. "settings window is used instead")
            UQ:Warn(UQ.L("SETTINGS_WARN_UNREALUI_REFUSED"))
            self:EnsureMinimapButton()
        end
        return self.host
    end

    if force then
        self.host = "standalone"
        UQ:DeclareCapability("unrealUISettingsHost", "missing",
            "unrealUI was not present after " .. HOST_POLL_SECONDS .. "s of polling, so UnrealQuest "
            .. "draws its options in its own window. Polled rather than read once at load: nothing "
            .. "establishes the two addons' load order, the client's TOC dependency fields have no "
            .. "record in the compatibility database, and ADDON_LOADED has no probed record here")
        self:EnsureMinimapButton()
    end
    return self.host
end

-- The minimap button --------------------------------------------------------
--
-- Built the moment the host settles on "standalone", and never otherwise. With
-- unrealUI installed its own settings button is already beside the minimap and
-- already opens the window that now holds this page, so a second button there
-- would be two controls for one destination -- and both would want the same
-- spot beside the map.

function Settings:ApplyMinimapButton()
    local button = self.minimapButton
    if not button then
        return false
    end
    if Setting("minimapButton") == false then
        return Client.HideObject(button)
    end
    return Client.ShowObject(button)
end

function Settings:EnsureMinimapButton()
    if self.minimapButton then
        return self.minimapButton
    end
    local button, anchor = Client.CreateMinimapButton(MINIMAP_BUTTON_NAME,
        "Interface\\ICONS\\INV_Misc_Gear_01")
    if not button then
        UQ:Debug("no settings button could be created beside the minimap")
        return nil
    end
    self.minimapButton = button
    self.minimapAnchor = anchor
    UQ:Debug("settings button anchored to " .. tostring(anchor))

    Client.SetObjectScript(button, "OnClick", function()
        Settings:Toggle()
    end)
    -- Chained, not replaced: the button was created with its own OnEnter/OnLeave
    -- driving the accent hover border, and Client.ChainScript is the layer's
    -- existing way to add a handler without dropping the one already there.
    Client.ChainScript(button, "OnEnter", function()
        Client.ShowGameTooltip(button, {
            { text = TAB_LABEL, r = UQ.colors.accent[1], g = UQ.colors.accent[2],
              b = UQ.colors.accent[3] },
            { text = UQ.L("SETTINGS_MINIMAP_TOOLTIP"), r = 0.7, g = 0.7, b = 0.7 },
        }, "ANCHOR_LEFT")
    end)
    Client.ChainScript(button, "OnLeave", function()
        Client.HideGameTooltip(button)
    end)

    self:ApplyMinimapButton()
    return button
end

-- The language selector ------------------------------------------------------
--
-- Four flat flags in the top-right of this window's header, opposite the
-- addon name. Not a dropdown: there are only four languages, and a player who
-- has just landed in one they cannot read needs the way back to be visible on
-- screen rather than one click inside a closed control.
--
-- ONLY IN THIS WINDOW. With unrealUI installed the language is whatever is set
-- there (Core/Locale.lua), and a second selector would be two controls writing
-- one value -- only one of which unrealUI would honour. UQ.SetLanguage refuses
-- the write in that case as well, so the two guards agree.
--
-- Changing the language does not retranslate what is already on screen: every
-- label in this addon is written once when its frame is built. The chat line
-- asking for a /reload is the whole of the confirmation, deliberately printed
-- in the language just chosen -- if the client's font has no glyphs for it, an
-- unreadable line is the fastest possible signal that this language will not
-- render, and the English flag is one visible click away.

local FLAG_WIDTH = 18
local FLAG_HEIGHT = 14
local FLAG_GAP = 3
local FLAG_RIGHT_INSET = 12

-- What the drag handle has to give up so these stay clickable. The handle
-- covers the header and is raised above it, so without this it would take
-- every click on the row.
local function LanguageSelectorInset()
    local count = table.getn(UQ.GetLanguages())
    return FLAG_RIGHT_INSET + count * (FLAG_WIDTH + FLAG_GAP)
end

-- Selection is communicated only through opacity: full for the active
-- language, 30% for the others, 95% while an inactive one is hovered -- so
-- pointing at the current choice never makes it look weaker.
local FLAG_SHADE_SELECTED = 1
local FLAG_SHADE_IDLE = 0.3
local FLAG_SHADE_HOVER = 0.95

function Settings:RefreshLanguageButtons()
    local active = UQ.GetLanguage()
    local index = 1
    local total = table.getn(self.languageButtons)
    while index <= total do
        local button = self.languageButtons[index]
        local selected = button.unrealQuestLanguage == active
        button.unrealQuestSelected = selected
        Client.SetSettingsFlagShade(button,
            selected and FLAG_SHADE_SELECTED or FLAG_SHADE_IDLE, selected)
        index = index + 1
    end
end

function Settings:BuildLanguageSelector(window)
    if UQ.IsLanguageFollowingUnrealUI() then
        return
    end

    local languages = UQ.GetLanguages()
    local count = table.getn(languages)
    -- Centred in the header strip: half the slack between its height and the
    -- flag's, so the row follows the header height rather than a fixed inset.
    local header = Client.GetSettingsMetrics()
    local flagTop = (header - FLAG_HEIGHT) / 2
    local index = 1
    while index <= count do
        local entry = languages[index]
        -- Captured per row: the closures below outlive this iteration.
        local code = entry.code
        local label = entry.label

        local button = Client.CreateSettingsFlag(window,
            "UnrealQuestSettingsLanguage" .. code,
            UQ.FlagTexture(code), entry.short, FLAG_WIDTH, FLAG_HEIGHT,
            function()
                if not UQ.SetLanguage(code) then
                    return
                end
                Settings:RefreshLanguageButtons()
                UQ:Print(UQ.L("SETTINGS_LANGUAGE_CHANGED", label))
                UQ:Print(UQ.L("SETTINGS_LANGUAGE_RELOAD"))
            end)
        if button then
            button.unrealQuestLanguage = code
            -- Right to left from the header's right edge, so the row keeps its
            -- inset however many languages are registered.
            Client.AnchorObject(button, "TOPRIGHT", window, "TOPRIGHT",
                -FLAG_RIGHT_INSET - (count - index) * (FLAG_WIDTH + FLAG_GAP),
                -flagTop)
            Client.SetObjectScript(button, "OnEnter", function()
                if button.unrealQuestSelected then
                    return
                end
                Client.SetSettingsFlagShade(button, FLAG_SHADE_HOVER, false)
            end)
            Client.SetObjectScript(button, "OnLeave", function()
                if button.unrealQuestSelected then
                    return
                end
                Client.SetSettingsFlagShade(button, FLAG_SHADE_IDLE, false)
            end)
            table.insert(self.languageButtons, button)
        end
        index = index + 1
    end

    self:RefreshLanguageButtons()
end

-- Shown and hidden with the window explicitly, never left to the parent. The
-- rest of this file already refuses to rely on a parent's visibility reaching
-- its children (SetRegionShown's note, rendering.parent_alpha_not_propagated),
-- and a flag that outlived its closed window would sit on the screen with
-- nothing behind it.
function Settings:SetLanguageSelectorShown(shown)
    local index = 1
    local total = table.getn(self.languageButtons)
    while index <= total do
        if shown then
            Client.ShowObject(self.languageButtons[index])
        else
            Client.HideObject(self.languageButtons[index])
        end
        index = index + 1
    end
end

-- The standalone window -----------------------------------------------------

function Settings:ApplyStoredPosition()
    local window = self.window
    if not window then
        return false
    end
    local point = Setting("settingsPoint")
    local relativePoint = Setting("settingsRelativePoint")
    local x = Setting("settingsX")
    local y = Setting("settingsY")
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end
    -- Always UIParent-relative, same rule as the tracker: a relative frame is a
    -- live object that cannot be persisted, and anchoring to another addon's
    -- frame would break the moment that addon is not loaded.
    return Client.SetFrameAnchor(window, point, "UIParent",
        type(relativePoint) == "string" and relativePoint or point, x, y)
end

function Settings:CapturePosition()
    local window = self.window
    if not window then
        return false
    end
    local point, relativeName, relativePoint, x, y = Client.GetFrameAnchor(window)
    if type(point) ~= "string" or type(x) ~= "number" or type(y) ~= "number" then
        UQ:Warn(UQ.L("SETTINGS_WARN_NO_POSITION"))
        return false
    end
    -- relativeName is read but not stored: whatever the drag left the window
    -- anchored to is normalized back to UIParent on the way in.
    Store("settingsPoint", point)
    Store("settingsRelativePoint", type(relativePoint) == "string" and relativePoint or point)
    Store("settingsX", x)
    Store("settingsY", y)
    return true
end

function Settings:ResetPosition()
    Store("settingsPoint", "CENTER")
    Store("settingsRelativePoint", "CENTER")
    Store("settingsX", 0)
    Store("settingsY", 0)
    self:ApplyStoredPosition()
end

function Settings:BuildWindow()
    if self.window then
        return self.window
    end

    local header, footer, padding = Client.GetSettingsMetrics()
    local window = Client.CreateSettingsWindow(WINDOW_NAME,
        CONTENT_WIDTH + padding * 2, CONTENT_HEIGHT + header + footer)
    if not window then
        UQ:Warn(UQ.L("SETTINGS_WARN_NO_WINDOW"))
        return nil
    end
    self.window = window
    -- Standalone only. The wordmark and version, not the plain TAB_LABEL: this
    -- window IS the addon's face when unrealUI is absent, so its header names
    -- the addon the way the addon list and the page's first line do. With
    -- unrealUI hosting, that host owns the menu row and this window is unused.
    Client.SetSettingsTitle(window, PageTitle())

    -- The handle stops short of the flag row so the header is draggable
    -- everywhere except where those buttons are. When unrealUI owns the
    -- language there is no row and the handle takes the whole strip.
    local handleInset = 0
    if not UQ.IsLanguageFollowingUnrealUI() then
        handleInset = LanguageSelectorInset()
    end
    local handle = Client.CreateSettingsHandle(window, HANDLE_NAME, handleInset)
    if handle then
        self.handle = handle
        Client.SetObjectScript(handle, "OnDragStart", function()
            if not Client.StartFrameDrag(window) then
                Settings.dragFailures = Settings.dragFailures + 1
                -- Visible, never debug-only: a drag that silently does nothing
                -- is the exact failure this client already produced once.
                UQ:Warn(UQ.L("SETTINGS_WARN_DRAG_FAILED"))
            end
        end)
        Client.SetObjectScript(handle, "OnDragStop", function()
            Client.StopFrameDrag(window)
            Settings:CapturePosition()
        end)
    else
        UQ:Warn(UQ.L("SETTINGS_WARN_NO_HANDLE"))
    end

    local close = Client.CreateTextButton(window, CLOSE_NAME, 80, 22, UQ.L("COMMON_CLOSE"))
    if close then
        self.close = close
        Client.AnchorObject(close, "BOTTOMRIGHT", window, "BOTTOMRIGHT", -padding, padding)
        Client.SetObjectScript(close, "OnClick", function()
            Settings:Close()
        end)
    end

    self:BuildLanguageSelector(window)

    self.content = Client.CreateSettingsContent(window, CONTENT_NAME)

    if not self:ApplyStoredPosition() then
        self:ResetPosition()
    end
    return window
end

-- Builds the page into the standalone window the first time it is opened.
-- unrealUI builds its own copy lazily too, on first selection of the row.
function Settings:EnsurePage()
    if self.page then
        return self.page
    end
    if not self.content then
        return nil
    end
    local widgets, refresh = self:BuildPage(self.content)
    self.page = { widgets = widgets or {}, refresh = refresh }
    return self.page
end

-- Shows or hides one region of a page, honouring the SAME composite convention
-- unrealUI's settings window uses: a control that owns extra regions hands them
-- back as `.label` (and a multi-part control as `uuiParts`), because nothing
-- here may rely on a parent's visibility reaching its children
-- (rendering.parent_alpha_not_propagated). Reproduced rather than invented, so
-- a control built by this page behaves identically in both windows.
local function SetRegionShown(region, shown)
    if not region then
        return
    end
    if region.uuiParts then
        local index = 1
        local total = table.getn(region.uuiParts)
        while index <= total do
            SetRegionShown(region.uuiParts[index], shown)
            index = index + 1
        end
        return
    end
    if shown then
        Client.ShowObject(region)
    else
        Client.HideObject(region)
    end
    if region.label then
        if shown then
            Client.ShowObject(region.label)
        else
            Client.HideObject(region.label)
        end
    end
end

local function SetPageShown(page, shown)
    if not page then
        return
    end
    local index = 1
    local total = table.getn(page.widgets)
    while index <= total do
        SetRegionShown(page.widgets[index], shown)
        index = index + 1
    end
end

-- Opening and closing -------------------------------------------------------

function Settings:Open()
    -- force: the player asked for the window now, so the decision cannot wait
    -- out the rest of the poll.
    local host = self:ResolveHost(true)
    self.opens = self.opens + 1

    if host == "unrealui" then
        local unrealUI = UnrealUI()
        if unrealUI and type(unrealUI.OpenSettingsPage) == "function" then
            local ok, opened = pcall(unrealUI.OpenSettingsPage, TAB_ID)
            if ok and opened then
                return true
            end
        end
        if unrealUI and type(unrealUI.OpenSettings) == "function" then
            -- Opens the panel without being able to select our row. Better than
            -- nothing: the row is in the list the player is now looking at.
            local ok = pcall(unrealUI.OpenSettings, true)
            if ok then
                return true
            end
        end
        UQ:Print(UQ.L("SETTINGS_IN_UNREALUI"))
        return false
    end

    if not self:BuildWindow() then
        return false
    end
    local page = self:EnsurePage()
    SetPageShown(page, true)
    self:SetLanguageSelectorShown(true)
    if page and type(page.refresh) == "function" then
        page.refresh()
    end
    return Client.ShowObject(self.window)
end

function Settings:Close()
    if self.host == "unrealui" then
        -- unrealUI's panel has no public close, and reaching past its API to
        -- hide its frame would be exactly the coupling this module avoids.
        return false
    end
    if not self.window then
        return false
    end
    SetPageShown(self.page, false)
    self:SetLanguageSelectorShown(false)
    return Client.HideObject(self.window)
end

function Settings:Toggle()
    if self.window and self.host ~= "unrealui" and Client.IsObjectShown(self.window) then
        return self:Close()
    end
    return self:Open()
end

function Settings:GetReport()
    return {
        host = self.host or "undecided",
        waited = self.hostWaited,
        registered = self.host == "unrealui",
        window = self.window ~= nil,
        page = self.page ~= nil,
        opens = self.opens,
        dragFailures = self.dragFailures,
        minimapButton = self.minimapButton ~= nil,
        minimapAnchor = self.minimapAnchor,
        minimapButtonShown = Setting("minimapButton") ~= false,
    }
end

-- Turns the minimap button on or off. `enabled` nil toggles. Does nothing on
-- the unrealUI host, where there is no button of ours to toggle.
function Settings:SetMinimapButtonEnabled(enabled)
    if enabled == nil then
        enabled = Setting("minimapButton") == false
    end
    Store("minimapButton", enabled and true or false)
    self:ApplyMinimapButton()
    return enabled and true or false
end

-- Lifecycle -----------------------------------------------------------------

function Settings:OnInit()
    UQ:DeclareCapability("unrealUISettingsHost", "unverified",
        "whether unrealUI is installed and will host UnrealQuest's options page. Resolved after the "
        .. "player is in the world, by polling for the UnrealUI global and type-checking its "
        .. "RegisterSettingsTab; this line is what it says before that poll has answered")
end

function Settings:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        -- No driver means no poll is possible at all, so decide now rather than
        -- leaving /uq config with no host.
        self:ResolveHost(true)
        return
    end
    -- Do not make a standalone player wait fifteen seconds just because this
    -- module also leaves room for unrealUI to finish loading. A later detected
    -- unrealUI hides this provisional copy before it can share the anchor.
    self:EnsureMinimapButton()
    driver:Schedule("settings.sliders", 0, function()
        Settings:RefreshLiveSliders()
    end)
    driver:Schedule("settings.host", HOST_POLL_INTERVAL, function(elapsed)
        Settings.hostWaited = Settings.hostWaited + (elapsed or HOST_POLL_INTERVAL)
        local host = Settings:ResolveHost(Settings.hostWaited >= HOST_POLL_SECONDS)
        if host then
            local running = UQ:GetModule("Driver")
            if running then
                running:Unschedule("settings.host")
            end
        end
    end)
end
