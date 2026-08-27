--[[
UnrealQuest / Quest/QuestLogButtons.lua

Two buttons above the native quest log's description pane, for whichever
quest is currently selected there:

  * Show           -- the same "take me there" gesture as Ctrl+click on the
                       tracker window: opens the fullscreen map and flashes
                       the quest's own pin(s), through
                       QuestClicks:RevealOnMap (Quest/QuestClicks.lua), shared
                       with the tracker so the two surfaces cannot drift
                       apart.
  * Track / Untrack -- toggles the quest in UnrealQuest's unlimited saved
                       tracked set through Quest/Tracker.lua, exactly what
                       /uq track / the tracker window's own gestures use.

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
local DOCK_NAME = "QuestLogDetailScrollChildFrame"
local PARENT_NAME = "QuestLogFrame"
local BUTTON_WIDTH = 72
local BUTTON_HEIGHT = 18
local BUTTON_GAP = 4
local DOCK_TITLE_EXTRA_HEIGHT = 28
local POLL_INTERVAL = 0.3

QuestLogButtons.buttons = nil
QuestLogButtons.currentQuest = nil
QuestLogButtons.dockTitlePrepared = false

local function QuestState()
    return UQ:GetModule("QuestState")
end

local function Tracker()
    return UQ:GetModule("Tracker")
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
    if not show or not track then
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

    QuestLogButtons.buttons = { show = show, track = track }
    return QuestLogButtons.buttons
end

local function AnchorButtons(buttons)
    local anchor = Client.GetNamedObject(ANCHOR_NAME)
    if anchor and PrepareDockTitle() then
        -- Left-aligned against the opened space's own left edge (TOPLEFT to
        -- TOPLEFT), not centered under the "Description" header.
        Client.PlaceInsideObject(buttons.show, anchor, 0, 0)
        Client.PlaceInsideObject(buttons.track, anchor, BUTTON_WIDTH + BUTTON_GAP, 0)
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

    local logFrame = Client.GetNamedObject(PARENT_NAME)
    if not logFrame or not Client.IsObjectShown(logFrame) then
        self.currentQuest = nil
        Client.HideObject(buttons.show)
        Client.HideObject(buttons.track)
        return
    end

    local quest = ResolveSelectedQuest()
    self.currentQuest = quest
    if not quest or not AnchorButtons(buttons) then
        Client.HideObject(buttons.show)
        Client.HideObject(buttons.track)
        return
    end

    Client.ShowObject(buttons.show)
    Client.ShowObject(buttons.track)

    local tracker = Tracker()
    local tracked = tracker and tracker:IsTracked(quest)
    Client.SetButtonLabel(buttons.track,
        tracked and UQ.L("QUESTLOG_BUTTON_UNTRACK") or UQ.L("QUESTLOG_BUTTON_TRACK"))
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
