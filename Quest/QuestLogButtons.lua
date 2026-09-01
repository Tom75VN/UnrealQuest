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

## What is shared between the surfaces, and what is not

The Following button, followed-row plaque and quest marker are properties of
UnrealQuest's model, not of a host theme, so they run on whichever quest log is
on screen. Both surfaces list the quest log through the SAME native
`QuestLogTitle<N>` rows -- unrealUI's modern panels reuse them, and the EQL3
extension merely repositions and multiplies them. The gutter between the
tracked bar and title carries the quest's map colour dot; following replaces
that dot with the quest marker, while the plaque begins at the title rather
than behind either gutter mark.

Three things stay modern-only, because each one depends on a widget that
unrealUI's panels supply and the native log does not lay out the same way: the
denser 18px row height (Client.SetModernQuestLogRowLayout), the recoloured
objective lines, and the quest level under the detail title -- the native log
already carries the level in the row text through Quest/QuestLogLevels.lua.

A fourth modern-only treatment deliberately lives in that module and not here:
the row's own name is tinted by quest difficulty there, in the same pass that
writes the level prefix, because the two are one fact about one row and uUI's
font pass would otherwise leave every quest the same colour.

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

QuestLogButtons.buttons = nil
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
            local quest = clicks and clicks:GetQuestFromLogRow(row) or nil
            local following = quest and mainQuest and mainQuest:IsMain(quest.titleKey)
            local red, green, blue
            if quest then
                red, green, blue = UQ.GetQuestColor(quest)
            end
            Client.SetQuestLogFollowingRow(row, following and true or false,
                red, green, blue)
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

    local logFrame = Client.GetNamedObject(PARENT_NAME)
    if not logFrame or not Client.IsObjectShown(logFrame) then
        self.currentQuest = nil
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
