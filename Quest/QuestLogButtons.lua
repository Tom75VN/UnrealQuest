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
                       side. The row is built by
                       Quest/QuestLanguageFlags.lua, which the quest-giver's
                       own windows share; only the anchor and the parenting
                       rule below are this pane's. It is the same row the
                       settings window's header carries
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

Two looks, chosen on every poll by Client.UsesQuestLogTexturedButtons. With
unrealUI absent, or hosting its modern-wow theme, the buttons wear authored
art: Show and Track the red button (media/128RedButton), Following the
gold-rimmed red one (media/128GoldRedButton), each a three-slice skin with a
recessed hover state -- see Client.SetQuestLogButtonSkin for the atlas layout
and the evidence behind drawing it that way. Every other unrealUI theme keeps
the flat look below.

The flat look matches unrealUI's "modern" look (near-black flat fill, one thin dark
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
    local anchor = Client.GetNamedObject(ANCHOR_NAME)
    local target = anchor or Client.GetNamedObject(PARENT_NAME)
    -- Same rule as AnchorModernButtons: the anchors already follow the scroll
    -- child, and clearing and reapplying them every poll makes the client
    -- reconsider which widget is under the mouse. While the pane scrolls under
    -- a resting cursor that re-fires OnEnter/OnLeave, and on the textured skin
    -- each one swaps the button's art -- a visible flicker.
    if target and buttons.classicAnchor == target then
        return true
    end
    QuestLogButtons.diagPlacements = (QuestLogButtons.diagPlacements or 0) + 1
    Client.SetObjectSize(buttons.show, BUTTON_WIDTH, BUTTON_HEIGHT)
    Client.SetObjectSize(buttons.track, BUTTON_WIDTH, BUTTON_HEIGHT)
    Client.SetObjectSize(buttons.follow, FOLLOW_BUTTON_WIDTH, BUTTON_HEIGHT)
    local followOffset = (BUTTON_WIDTH + BUTTON_GAP) * 2
    if anchor and PrepareDockTitle() then
        buttons.classicAnchor = anchor
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
    buttons.classicAnchor = parent
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
    Client.SetQuestLogFocusTextureInset()
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
    -- A return to the native surface must place the classic row again.
    buttons.classicAnchor = nil
    QuestLogButtons.diagPlacements = (QuestLogButtons.diagPlacements or 0) + 1
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
--
-- The row itself lives in Quest/QuestLanguageFlags.lua, because the
-- quest-giver's windows draw the same one. All that is local to this pane is
-- which frame it hangs off and how it is parented: the detail VIEWPORT as the
-- anchor and QuestLogFrame as the parent, for the reasons spelled out above
-- Client.PlaceQuestLogFlag.
local FLAG_ROW_KEY = "questlog"
local FLAG_NAME_PREFIX = "UnrealQuestLogLanguageFlag"
-- Under unrealUI's modern-wow theme the right page's art leaves the row too
-- close to the page edge, so the whole row sits this far further left there.
local MODERN_WOW_FLAG_SHIFT_X = 29

-- Client.PlaceQuestLogFlag with the host-theme nudge applied. The theme is
-- read per placement, so switching themes moves the row on its next refresh.
local function PlaceQuestLogFlag(button, anchor, offsetX, offsetY)
    if Client.IsUnrealUIModernWowTheme() then
        offsetX = offsetX - MODERN_WOW_FLAG_SHIFT_X
    end
    return Client.PlaceQuestLogFlag(button, anchor, offsetX, offsetY)
end

local function RefreshFlags(quest)
    local flags = UQ:GetModule("QuestLanguageFlags")
    if not flags then
        return
    end
    flags:Refresh({
        key = FLAG_ROW_KEY,
        namePrefix = FLAG_NAME_PREFIX,
        quest = quest,
        anchor = Client.GetQuestLogDetailAnchor(),
        place = PlaceQuestLogFlag,
        translation = Translation(),
        onChanged = function()
            QuestLogButtons:Refresh()
        end,
    })
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
    -- Diagnostic counter, read by UnrealRuntimeProbe's questlogbtnflicker.
    self.diagRefreshes = (self.diagRefreshes or 0) + 1
    local buttons = EnsureButtons()
    if not buttons then
        return
    end

    -- Diagnostic step switches, set only by UnrealRuntimeProbe's
    -- questlogbtnbisect while it runs; empty and inert otherwise.
    local skip = self.diagSkip or {}

    local modern = Client.HasModernQuestLog()
    if modern and not skip.panelLayout then
        Client.SetModernQuestLogPanelLayout()
    end
    if not skip.rowsFollowing then
        SetRowsFollowing(modern)
    end
    -- SetRowsFollowing is where the modern row height is applied, so this is
    -- where the taller rows have to be kept inside the host's list page: the
    -- host sized its row count for the stock height, and the surplus belongs
    -- on the scroll bar rather than over the footer buttons. Measured against
    -- the live rows, so it is inert on a layout that already fits.
    if not skip.fitRows then
        Client.FitQuestLogRowsToList()
    end

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
    if not skip.flags then
        RefreshFlags(quest)
    end
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

    if not skip.showButtons then
        Client.ShowObject(buttons.show)
        Client.ShowObject(buttons.track)
    end

    -- Read every poll, like the flag nudge: a host that initialises late or a
    -- theme switch swaps the skin on the next pass. Applied after anchoring so
    -- the slices take the size this surface just gave the buttons, and before
    -- UpdateFollowButton so its active state knows which chrome it is on.
    if not skip.skin then
        local textured = Client.UsesQuestLogTexturedButtons()
        Client.SetQuestLogButtonSkin(buttons.show, textured and "red" or nil)
        Client.SetQuestLogButtonSkin(buttons.track, textured and "red" or nil)
        Client.SetQuestLogButtonSkin(buttons.follow, textured and "gold" or nil)
    end

    if not skip.trackLabel then
        local tracker = Tracker()
        local tracked = tracker and tracker:IsTracked(quest)
        Client.SetButtonLabel(buttons.track,
            tracked and UQ.L("QUESTLOG_BUTTON_UNTRACK") or UQ.L("QUESTLOG_BUTTON_TRACK"))
    end

    if not skip.followButton then
        UpdateFollowButton(buttons, quest)
    end

    if modern then
        local modernWow = Client.IsUnrealUIModernWowTheme()
        local dock = Client.GetNamedObject(DOCK_NAME)
        -- The 1px accent rule above the action row belongs to uUI's Modern
        -- look; the modern-wow page art draws its own edge, so it is hidden
        -- there. Read per poll so a theme switch follows.
        local modernAnchor = Client.GetNamedObject(MODERN_ANCHOR_NAME)
        if dock and modernAnchor then
            Client.SetModernQuestLogActionRule(dock, modernAnchor,
                not modernWow)
        end
        -- USER_CONFIRMED_INGAME + questrewardlayout.live_scroll_sequence.v4:
        -- unrealUI's modern-wow Quest Log shows the native coins when
        -- UnrealQuest is disabled. Reparenting QuestLogMoneyFrame afterward
        -- leaves it invisible even with a valid range at maximum scroll.
        -- Preserve the client's working ownership on this one theme; the flat
        -- modern host still needs the established attachment path.
        if not skip.rewards and not modernWow then
            Client.AttachModernQuestLogRewards(dock)
        end
        if not skip.objectiveColors then
            Client.SetModernQuestLogObjectiveColors(quest.objectives)
        end

        if not skip.level then
            local title = Client.GetNamedObject("QuestLogQuestTitle")
            local label = Client.PrepareModernQuestLogLevel(dock, title)
            Client.SetModernQuestLogLevel(label,
                UQ.L("QUESTLOG_LEVEL", tostring(quest.level or "?")), true)
        end
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
