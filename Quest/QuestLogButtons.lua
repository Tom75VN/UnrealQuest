--[[
UnrealQuest / Quest/QuestLogButtons.lua

Action buttons in the quest log detail pane, for whichever quest is currently
selected there. Both surfaces -- the native/classic log (standalone, or
unrealUI's Classic WoW theme, extended onto the two EQL3 parchment pages by
Quest/ExtendedQuestLog.lua) and unrealUI's modern two-pane log -- carry Show,
Track/Untrack and Following, and mark the followed quest in the list with the
gold plaque and its quest marker.

  * Show           -- the same "take me there" gesture as Ctrl+click on the
                       tracker window: opens the fullscreen map and flashes
                       the quest's own pin(s), through
                       QuestClicks:RevealOnMap (Quest/QuestClicks.lua), shared
                       with the tracker so the two surfaces cannot drift
                       apart.
  * Track / Untrack -- toggles the quest in UnrealQuest's unlimited saved
                       tracked set through Quest/Tracker.lua, exactly what
                       /uq track / the tracker window's own gestures use.
  * Following      -- selects the quest the navigator arrow and the HUD
                       follow, through QuestClicks:Select, and wears the
                       reference gold active state while it is the followed
                       one. The same gesture the tracker window's own rows use.

A fourth control sits apart from that row, in the detail pane's top-right
corner: the language flags. They are anchored to the detail VIEWPORT on both
surfaces and parented to QuestLogFrame -- see Client.PlaceQuestLogFlag for why
neither uUI's own detail panel nor the scroll child is the right frame.

  * Flags          -- one flag per language this quest can be read in, side by
                       side, the same row the settings window's header carries
                       and read the same way: full opacity is the language the
                       quest is in, 30% the others, 95% under the cursor.
                       Clicking one puts THIS quest in that language --
                       title, objective summary and description -- without
                       touching the account-wide translateQuestTitles setting
                       and without a reload. It writes a per-quest language
                       (Quest/QuestLogTranslation.lua, stored in
                       Core/Locale.lua) and the detail pane is reapplied in the
                       same click.

                       The row's first flag is the CLIENT's own locale, and it
                       always appears: it needs no bundled row, it is the text
                       the server actually sent, and it is the way back for a
                       player whose font cannot draw the language they picked.
                       The rest are the bundled languages that have a real row
                       for this quest, in the settings row's own order, packed
                       against the right edge so a quest missing one of them
                       leaves no hole.

                       Drawn 30% smaller than the settings header's flags,
                       because this row sits inside the quest text rather than
                       in chrome of its own.

                       The scope is the QUEST, not this panel: every surface
                       asks Database:GetQuestDisplayText, so the tracker, the
                       map pins and the tooltips follow along on their own next
                       poll. "Only this quest" means one quest everywhere, not
                       one panel.

                       The whole row is drawn only when there is a choice: an
                       unambiguous quest ID, and at least one bundled language
                       beside the client's own.

## Placement

QuestLogDescriptionTitle's TOPLEFT anchor point does not move to wherever
"above the description" visually turns out to be for a given quest (its
position is wherever stock FrameXML's own layout chain puts it, not
predictable field-to-field) -- a first attempt anchoring BOTTOMLEFT-to-TOPLEFT
above it landed the buttons up near the quest title instead, confirmed
in-game. pfQuest's own quest-log integration (pfQuest/quest.lua
AddQuestLogIntegration, proven working prior art -- reference only, see
the project instructions) solves this differently: it grows
QuestLogDescriptionTitle's own
height by a fixed amount and bottom-justifies its text, which pushes the
"Description" label down inside its own (now taller) bounds without moving
its anchor, opening blank space at the top of that bounds. This module
reproduces the height/justify half of that recipe via Client.GrowObjectHeight
and Client.SetFontStringJustifyV (Compatibility/ClientAPI.lua), done once per
login (PrepareDockTitle below) since growing the height is not idempotent to
repeat -- but anchors its own buttons TOPLEFT-to-TOPLEFT (Client.PlaceInsideObject)
against that opened space's left edge rather than pfQuest's TOP-to-TOP-centered
placement, so the pair reads left-aligned instead of centered under the
header. The buttons are parented to QuestLogDetailScrollChildFrame (pfQuest's
"dockFrame"), not QuestLogFrame, so they scroll with the rest of the detail
pane exactly as pfQuest's own buttons do.

The modern unrealUI path instead grows QuestLogRewardTitleText and places the
three-button action row after the description and immediately before Rewards.
It is detected through unrealUI's two named modern panels, which are absent in
Classic WoW and when unrealUI is not installed.

Styling matches unrealUI's "modern" look (near-black flat fill, one thin dark
outline, orange accent border on hover) via Client.CreateStyledTextButton --
not a dependency on unrealUI itself, but the same FLAT_BACKGROUND/
BuildFlatBorder recipe this addon already uses for the tracker window and
native-frame tooltips (Compatibility/ClientAPI.lua), backed by the same
client evidence (knowledge.json rendering.backdrop_edge_fractional_not_rasterized):
a fractional SetBackdrop edgeSize does not reliably rasterize here, so the
outline is four plain textures rather than a backdrop edge.

QuestLogFrame's structure carries BEHAVIOR_VERIFIED evidence (/urp interface
QuestLogFrame, diagnostics/unreal-runtime/compat/interface.json, capturedAt
2026-08-23, confirming QuestLogFrame, QuestLogDetailScrollFrame,
QuestLogDetailScrollChildFrame and QuestLogDescriptionTitle all exist here),
so questLogButtons is declared "verified" -- see OnInit below. The exact pixel
placement produced by growing/justifying is still pending an in-game visual
check, since the probe does not capture on-screen coordinates.

## Selection tracking

This client has no quest-log-selection-changed event this addon trusts (rule:
events are accelerators, never the mechanism), so the selected quest is
polled from Client.GetQuestLogSelection() on the shared driver, the same
technique every other periodic job in this addon uses. The buttons hide
whenever nothing is resolved (log closed, a header selected, or a row this
addon's model does not carry) rather than staying stale on the last quest.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestLogButtons = UQ:NewModule("QuestLogButtons")

local ANCHOR_NAME = "QuestLogDescriptionTitle"
local MODERN_ANCHOR_NAME = "QuestLogRewardTitleText"
local DOCK_NAME = "QuestLogDetailScrollChildFrame"
local PARENT_NAME = "QuestLogFrame"
local BUTTON_WIDTH = 72
local BUTTON_HEIGHT = 18
local BUTTON_GAP = 4
-- "Following" is the longest label the row carries, in every locale, so the
-- classic row widens that one button rather than all three -- the same
-- proportion the modern row uses (104 against 84).
local FOLLOW_BUTTON_WIDTH = 90
local MODERN_BUTTON_WIDTH = 84
local MODERN_FOLLOW_WIDTH = 104
local MODERN_BUTTON_HEIGHT = 30
local DOCK_TITLE_EXTRA_HEIGHT = 28
local POLL_INTERVAL = 0.3
local MAX_LOG_ROWS = 30

-- The language row. 30% off the settings header's 18x14 and its 3-pixel gap,
-- because this row sits inside the quest text rather than in a chrome strip of
-- its own. The inset is measured from the detail viewport's top-right corner
-- and kept small: the scroll bar sits outside that corner.
local FLAG_WIDTH = 13
local FLAG_HEIGHT = 10
local FLAG_GAP = 2
local FLAG_INSET_X = -6
local FLAG_INSET_Y = -4

-- The settings row's own three shades, for the same reason it has them:
-- selection is communicated by opacity alone, and pointing at the current
-- choice must never make it look weaker than the others.
local FLAG_SHADE_SELECTED = 1
local FLAG_SHADE_IDLE = 0.3
local FLAG_SHADE_HOVER = 0.95

QuestLogButtons.buttons = nil
QuestLogButtons.flags = nil
QuestLogButtons.flagCodes = nil
QuestLogButtons.currentQuest = nil
QuestLogButtons.dockTitlePrepared = false

local function QuestState()
    return UQ:GetModule("QuestState")
end

local function Tracker()
    return UQ:GetModule("Tracker")
end

local function MainQuest()
    return UQ:GetModule("MainQuest")
end

local function QuestClicks()
    return UQ:GetModule("QuestClicks")
end

local function Translation()
    return UQ:GetModule("QuestLogTranslation")
end

-- Widgets ---------------------------------------------------------------

-- Growing QuestLogDescriptionTitle's height is not idempotent to repeat (each
-- call would grow it again), so this runs once per login, guarded by
-- dockTitlePrepared, the moment the title first resolves -- matching
-- pfQuest's own one-shot SetHeight/SetJustifyV call in AddQuestLogIntegration.
local function PrepareDockTitle()
    if QuestLogButtons.dockTitlePrepared then
        return true
    end
    local title = Client.GetNamedObject(ANCHOR_NAME)
    if not title then
        return false
    end
    Client.GrowObjectHeight(title, DOCK_TITLE_EXTRA_HEIGHT)
    Client.SetFontStringJustifyV(title, "BOTTOM")
    QuestLogButtons.dockTitlePrepared = true
    return true
end

local function EnsureButtons()
    if QuestLogButtons.buttons then
        return QuestLogButtons.buttons
    end
    local dock = Client.GetNamedObject(DOCK_NAME) or Client.GetNamedObject(PARENT_NAME)
    if not dock then
        return nil
    end
    local show = Client.CreateStyledTextButton(dock, "UnrealQuestLogShowButton",
        BUTTON_WIDTH, BUTTON_HEIGHT, UQ.L("QUESTLOG_BUTTON_SHOW"))
    local track = Client.CreateStyledTextButton(dock, "UnrealQuestLogTrackButton",
        BUTTON_WIDTH, BUTTON_HEIGHT, UQ.L("QUESTLOG_BUTTON_TRACK"))
    local follow = Client.CreateStyledTextButton(dock, "UnrealQuestLogFollowButton",
        BUTTON_WIDTH, BUTTON_HEIGHT, UQ.L("QUESTLOG_BUTTON_FOLLOW"))
    if not show or not track or not follow then
        return nil
    end

    Client.SetObjectScript(show, "OnClick", function()
        local quest = QuestLogButtons.currentQuest
        if not quest then
            return
        end
        local clicks = QuestClicks()
        if clicks then
            clicks:RevealOnMap(quest)
        end
    end)

    Client.SetObjectScript(track, "OnClick", function()
        local quest = QuestLogButtons.currentQuest
        if not quest then
            return
        end
        local tracker = Tracker()
        if tracker then
            tracker:Toggle(quest)
        end
        QuestLogButtons:Refresh()
    end)

    Client.SetObjectScript(follow, "OnClick", function()
        local quest = QuestLogButtons.currentQuest
        local clicks = QuestClicks()
        if quest and clicks then
            clicks:Select(quest, "questLogButton")
        end
        QuestLogButtons:Refresh()
    end)

    Client.HideObject(follow)
    QuestLogButtons.buttons = { show = show, track = track, follow = follow }
    return QuestLogButtons.buttons
end

local function AnchorButtons(buttons)
    -- A return from the native surface must rebuild the modern anchors even
    -- when unrealUI reused the same named frames.
    buttons.modernAnchor = nil
    buttons.modernDock = nil
    Client.SetObjectSize(buttons.show, BUTTON_WIDTH, BUTTON_HEIGHT)
    Client.SetObjectSize(buttons.track, BUTTON_WIDTH, BUTTON_HEIGHT)
    Client.SetObjectSize(buttons.follow, FOLLOW_BUTTON_WIDTH, BUTTON_HEIGHT)
    local followOffset = (BUTTON_WIDTH + BUTTON_GAP) * 2
    local anchor = Client.GetNamedObject(ANCHOR_NAME)
    if anchor and PrepareDockTitle() then
        -- Left-aligned against the opened space's own left edge (TOPLEFT to
        -- TOPLEFT), not centered under the "Description" header.
        Client.PlaceInsideObject(buttons.show, anchor, 0, 0)
        Client.PlaceInsideObject(buttons.track, anchor, BUTTON_WIDTH + BUTTON_GAP, 0)
        Client.PlaceInsideObject(buttons.follow, anchor, followOffset, 0)
        return true
    end

    -- ANCHOR_NAME not found on this client; fall back to the top of
    -- QuestLogFrame itself so the buttons still show up somewhere useful.
    local parent = Client.GetNamedObject(PARENT_NAME)
    if not parent then
        return false
    end
    Client.PlaceInsideObject(buttons.show, parent, 8, -60)
    Client.PlaceInsideObject(buttons.track, parent, 8 + BUTTON_WIDTH + BUTTON_GAP, -60)
    Client.PlaceInsideObject(buttons.follow, parent, 8 + followOffset, -60)
    return true
end

-- The row height is the only half of this that belongs to the modern surface;
-- the plaque and its quest marker mark the followed quest on whichever list is
-- on screen, since both lists are the same native rows.
local function SetRowsFollowing(modern)
    local clicks = QuestClicks()
    local mainQuest = MainQuest()
    local index = 1
    while index <= MAX_LOG_ROWS do
        local row = Client.GetNamedObject("QuestLogTitle" .. tostring(index))
        if row then
            if modern or row.unrealQuestOriginalHeight ~= nil then
                Client.SetModernQuestLogRowLayout(row, modern)
            end
            local quest = clicks and clicks:GetQuestFromLogRow(row, index) or nil
            local following = quest and mainQuest and mainQuest:IsMain(quest.titleKey)
            local red, green, blue
            if quest then
                red, green, blue = UQ.GetQuestColor(quest)
            end
            Client.SetQuestLogFollowingRow(row, following and true or false,
                red, green, blue, modern)
        end
        index = index + 1
    end
end

-- The button's own label carries the state -- "Following" in the reference
-- gold while this is the followed quest, "Follow" otherwise -- so both
-- surfaces read it the same way.
local function UpdateFollowButton(buttons, quest)
    local mainQuest = MainQuest()
    local following = quest and mainQuest and mainQuest:IsMain(quest.titleKey) or false
    buttons.follow.unrealQuestActiveText = following
        and UQ.L("TRACKER_FOLLOWING") or UQ.L("QUESTLOG_BUTTON_FOLLOW")
    Client.SetButtonLabel(buttons.follow, buttons.follow.unrealQuestActiveText)
    Client.SetStyledTextButtonActive(buttons.follow, following)
    Client.ShowObject(buttons.follow)
end

local function HideLevel()
    local dock = Client.GetNamedObject(DOCK_NAME)
    local label = dock and dock.unrealQuestLevelLabel
    if label then
        Client.SetModernQuestLogLevel(label, "", false)
    end
end

local function AnchorModernButtons(buttons)
    local anchor = Client.GetNamedObject(MODERN_ANCHOR_NAME)
    local dock = Client.GetNamedObject(DOCK_NAME)
    if not anchor or not dock then
        return false
    end
    -- These anchors follow the reward block automatically. Re-clearing and
    -- reapplying them on every poll makes the client briefly reconsider which
    -- widget is under the mouse, producing a repeating hover blink.
    if buttons.modernAnchor == anchor and buttons.modernDock == dock then
        return true
    end
    if not Client.PlaceModernQuestLogAction(buttons.show, anchor, 0,
        MODERN_BUTTON_WIDTH, MODERN_BUTTON_HEIGHT) then
        return false
    end
    Client.PlaceModernQuestLogAction(buttons.track, anchor,
        MODERN_BUTTON_WIDTH + BUTTON_GAP, MODERN_BUTTON_WIDTH, MODERN_BUTTON_HEIGHT)
    Client.PlaceModernQuestLogAction(buttons.follow, anchor,
        (MODERN_BUTTON_WIDTH + BUTTON_GAP) * 2,
        MODERN_FOLLOW_WIDTH, MODERN_BUTTON_HEIGHT)
    Client.SetModernQuestLogActionRule(dock, anchor, true)
    buttons.modernAnchor = anchor
    buttons.modernDock = dock
    return true
end

-- The language row -----------------------------------------------------------

-- The roster is fixed for the session: the languages this addon carries flags
-- for, in the settings row's order, plus the client's own locale when it is
-- not one of them. WHICH of these a given quest actually offers changes per
-- quest and is decided in RefreshFlags; this only decides what exists and in
-- what order it reads.
local function FlagRoster()
    if QuestLogButtons.flagCodes then
        return QuestLogButtons.flagCodes
    end
    local languages = UQ.GetLanguages()
    if not languages then
        return nil
    end
    local codes = {}
    local seen = {}
    local index = 1
    local total = table.getn(languages)
    while index <= total do
        local code = languages[index].code
        table.insert(codes, code)
        seen[code] = true
        index = index + 1
    end
    local clientLanguage = Client.GetLocale()
    if type(clientLanguage) == "string" and not seen[clientLanguage] then
        table.insert(codes, 1, clientLanguage)
    end
    QuestLogButtons.flagCodes = codes
    return codes
end

local function FlagTooltip(button)
    local translation = Translation()
    local quest = QuestLogButtons.currentQuest
    local code = button.unrealQuestLanguage
    if not translation or not quest or type(code) ~= "string" then
        return
    end
    local native = code == Client.GetLocale()
    Client.ShowGameTooltip(button, {
        { text = UQ.GetLanguageLabel(code), r = UQ.colors.accent[1],
          g = UQ.colors.accent[2], b = UQ.colors.accent[3] },
        { text = native and UQ.L("QUESTLOG_FLAG_NATIVE")
            or UQ.L("QUESTLOG_FLAG_TRANSLATED"), r = 0.9, g = 0.9, b = 0.9 },
        { text = UQ.L("QUESTLOG_FLAG_ONLY_THIS_QUEST"), r = 0.7, g = 0.7, b = 0.7 },
    }, "ANCHOR_LEFT")
end

-- Built once per language; Client.PlaceQuestLogFlag then reparents each to
-- QuestLogFrame and keeps it there. There is no rebuild, because this client
-- cannot destroy a frame. Each is created WITH artwork rather than with the
-- ASCII badge: Client.CreateFlagButton only makes the icon texture when it is
-- handed a path, and a flag that started as a badge could never grow one.
local function EnsureFlags(parent)
    if QuestLogButtons.flags then
        return QuestLogButtons.flags
    end
    local codes = FlagRoster()
    if not codes then
        return nil
    end

    local flags = {}
    local index = 1
    local total = table.getn(codes)
    while index <= total do
        -- Captured per row: the closures below outlive this iteration.
        local code = codes[index]
        local button = Client.CreateFlagButton(parent,
            "UnrealQuestLogLanguageFlag" .. code,
            UQ.FlagTexture(code), UQ.GetLanguageBadge(code),
            FLAG_WIDTH, FLAG_HEIGHT)
        if button then
            button.unrealQuestLanguage = code
            Client.SetObjectScript(button, "OnClick", function()
                local translation = Translation()
                local quest = QuestLogButtons.currentQuest
                if not translation or not quest then
                    return
                end
                if not translation:SetQuestLanguage(quest, code) then
                    return
                end
                QuestLogButtons:Refresh()
                FlagTooltip(button)
            end)
            Client.SetObjectScript(button, "OnEnter", function()
                if not button.unrealQuestSelected then
                    Client.SetFlagButtonShade(button, FLAG_SHADE_HOVER, false)
                end
                FlagTooltip(button)
            end)
            Client.SetObjectScript(button, "OnLeave", function()
                if not button.unrealQuestSelected then
                    Client.SetFlagButtonShade(button, FLAG_SHADE_IDLE, false)
                end
                Client.HideGameTooltip(button)
            end)
            Client.HideObject(button)
            flags[code] = button
        end
        index = index + 1
    end

    QuestLogButtons.flags = flags
    return flags
end

local function HideFlags()
    local flags = QuestLogButtons.flags
    if not flags then
        return
    end
    local codes = QuestLogButtons.flagCodes
    local index = 1
    local total = codes and table.getn(codes) or 0
    while index <= total do
        local button = flags[codes[index]]
        if button then
            Client.HideObject(button)
        end
        index = index + 1
    end
end

local function RefreshFlags(quest)
    local translation = Translation()
    local anchor = Client.GetQuestLogDetailAnchor()
    if not translation or not quest or not anchor
        or not translation:CanChooseLanguage(quest) then
        HideFlags()
        return
    end
    local flags = EnsureFlags(anchor)
    local codes = QuestLogButtons.flagCodes
    if not flags or not codes then
        return
    end

    -- Membership, not order: the row reads in the roster's order, while
    -- GetLanguageChoices answers in the module's own (client language first).
    local offered = {}
    local choices = translation:GetLanguageChoices(quest)
    local index = 1
    local total = choices and table.getn(choices) or 0
    while index <= total do
        offered[choices[index]] = true
        index = index + 1
    end

    -- Two passes, because the position of the first flag depends on how many
    -- follow it: a quest missing one language must leave no hole in the row.
    local shown = {}
    index = 1
    total = table.getn(codes)
    while index <= total do
        local code = codes[index]
        local button = flags[code]
        if button and offered[code] then
            table.insert(shown, button)
        elseif button then
            Client.HideObject(button)
        end
        index = index + 1
    end

    local current = translation:GetQuestLanguage(quest)
    local count = table.getn(shown)
    index = 1
    while index <= count do
        local button = shown[index]
        -- Right to left from the viewport's right edge, exactly as the
        -- settings header lays its own row out.
        local offsetX = FLAG_INSET_X - (count - index) * (FLAG_WIDTH + FLAG_GAP)
        if Client.PlaceQuestLogFlag(button, anchor, offsetX, FLAG_INSET_Y) then
            local selected = button.unrealQuestLanguage == current
            button.unrealQuestSelected = selected
            Client.SetFlagButtonShade(button,
                selected and FLAG_SHADE_SELECTED or FLAG_SHADE_IDLE, selected)
            Client.ShowObject(button)
        else
            Client.HideObject(button)
        end
        index = index + 1
    end
end

-- Resolving the current quest ------------------------------------------------
--
-- Neither surface hands over a quest id -- this client has none. The selected
-- row's title is read back through GetQuestLogEntry (the same six-value call
-- QuestClicks.lua relies on) and matched against the quest model by title,
-- the only stable join this addon has.
local function ResolveSelectedQuest()
    local index = Client.GetQuestLogSelection()
    if not index then
        return nil
    end
    local title, _, _, isHeader = Client.GetQuestLogEntry(index)
    if not title or isHeader then
        return nil
    end
    local questState = QuestState()
    if not questState then
        return nil
    end
    return questState:GetQuestByTitle(title)
end

-- Refresh ---------------------------------------------------------------

function QuestLogButtons:Refresh()
    local buttons = EnsureButtons()
    if not buttons then
        return
    end

    local modern = Client.HasModernQuestLog()
    if modern then
        Client.SetModernQuestLogPanelLayout()
    end
    SetRowsFollowing(modern)
    -- SetRowsFollowing is where the modern row height is applied, so this is
    -- where the taller rows have to be kept inside the host's list page: the
    -- host sized its row count for the stock height, and the surplus belongs
    -- on the scroll bar rather than over the footer buttons. Measured against
    -- the live rows, so it is inert on a layout that already fits.
    Client.FitQuestLogRowsToList()

    local logFrame = Client.GetNamedObject(PARENT_NAME)
    if not logFrame or not Client.IsObjectShown(logFrame) then
        self.currentQuest = nil
        RefreshFlags(nil)
        Client.HideObject(buttons.show)
        Client.HideObject(buttons.track)
        Client.HideObject(buttons.follow)
        if modern then
            Client.SetModernQuestLogObjectiveColors(nil)
        end
        HideLevel()
        return
    end

    local quest = ResolveSelectedQuest()
    self.currentQuest = quest
    -- Independent of the action row: the flags anchor to the detail viewport
    -- itself, so they still show on a surface where the action row's own
    -- anchor could not be prepared.
    RefreshFlags(quest)
    local anchored = false
    if quest then
        if modern then
            anchored = AnchorModernButtons(buttons)
        else
            anchored = AnchorButtons(buttons)
        end
    end
    if not quest or not anchored then
        Client.HideObject(buttons.show)
        Client.HideObject(buttons.track)
        Client.HideObject(buttons.follow)
        if modern then
            Client.SetModernQuestLogObjectiveColors(nil)
        end
        HideLevel()
        return
    end

    Client.ShowObject(buttons.show)
    Client.ShowObject(buttons.track)

    local tracker = Tracker()
    local tracked = tracker and tracker:IsTracked(quest)
    Client.SetButtonLabel(buttons.track,
        tracked and UQ.L("QUESTLOG_BUTTON_UNTRACK") or UQ.L("QUESTLOG_BUTTON_TRACK"))

    UpdateFollowButton(buttons, quest)

    if modern then
        local dock = Client.GetNamedObject(DOCK_NAME)
        Client.AttachModernQuestLogRewards(dock)
        Client.SetModernQuestLogObjectiveColors(quest.objectives)

        local title = Client.GetNamedObject("QuestLogQuestTitle")
        local label = Client.PrepareModernQuestLogLevel(dock, title)
        Client.SetModernQuestLogLevel(label,
            UQ.L("QUESTLOG_LEVEL", tostring(quest.level or "?")), true)
    else
        -- The native row text already carries the level (Quest/QuestLogLevels),
        -- so the detail-title label stays a modern-only addition.
        HideLevel()
        local dock = Client.GetNamedObject(DOCK_NAME)
        local modernAnchor = Client.GetNamedObject(MODERN_ANCHOR_NAME)
        if dock and modernAnchor and dock.unrealQuestActionRule then
            Client.SetModernQuestLogActionRule(dock, modernAnchor, false)
        end
    end
end

-- Lifecycle ------------------------------------------------------------------

function QuestLogButtons:OnInit()
    UQ:DeclareCapability("questLogButtons", "verified",
        "/urp interface QuestLogFrame (BEHAVIOR_VERIFIED, "
        .. "diagnostics/unreal-runtime/compat/interface.json, capturedAt 2026-08-23) confirms "
        .. "QuestLogFrame, QuestLogDetailScrollFrame, QuestLogDetailScrollChildFrame and "
        .. "QuestLogDescriptionTitle all exist on this client in the standard Vanilla FrameXML "
        .. "layout order")
end

function QuestLogButtons:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("questlog.buttons", POLL_INTERVAL, function()
        QuestLogButtons:Refresh()
    end)
end
