--[[
UnrealQuest / Quest/QuestGiverTranslation.lua

The language flags on the quest-giver's OFFER window, and the translated title,
objectives and description they switch it to. The same row, the same per-quest
override and the same three database fields as the quest log detail pane
(Quest/QuestLogTranslation.lua); this module exists because the window they sit
on answers none of the questions that one asks.

## Why the log's module could not simply be pointed at this frame

Three things differ, and each of them is load-bearing:

  1. THERE IS NO QUEST LOG ROW. An offered quest is not in the log yet, so
     there is no index, no level and no objective list to match on. The quest
     is resolved by Match:ResolveGiverQuestId (Data/QuestMatch.lua) from the
     three strings the giver packet carries, which is also what the reward
     rows on this same window use -- deliberately the same call, so the two
     things drawn on one panel cannot disagree about which quest it is.

  2. THE FIELDS HAVE NO NAME THIS ADDON HAS EVIDENCE FOR. The confirmed record
     quest_dialog.detail_reward_text_globals (USER_CONFIRMED_INGAME,
     2026-08-20) establishes this panel's HEADING globals and explicitly
     establishes that the generic quest text globals are NOT the visible
     strings here. It says nothing about the three body strings under those
     headings, and writing to a guessed Vanilla name is the assumption rule 3
     forbids. So the fields are found by CONTENT instead: the client is asked
     what the title, objectives and description of the open window are
     (GetTitleText, GetObjectiveText, GetQuestText), and the FontString under
     the panel whose text is exactly one of those three IS that field. Nothing
     is ever written to an object that has not first been observed holding the
     string it is supposed to be holding, which makes a wrong binding
     impossible rather than merely unlikely. A panel where no string matches
     costs the player the feature and nothing else.

     The names have since been MEASURED -- the walk binds objects that answer
     GetName() with QuestTitleText, QuestObjectiveText and QuestDescription
     (questgiver.region_walk_returns_same_objects.v1, and the inventory in the
     questgivertext run of 2026-09-10). The binding stays content-first anyway,
     because a name that was true for one quest on one day is an assumption on
     the next and this test verifies itself every pass. What the measurement
     buys is the exchange in BindFields: the walked wrapper is swapped for the
     global OF THAT SAME NAME, which is the only handle this client will accept
     a write through.

  3. THE CLIENT REWRITES THE PANEL ON EVERY PACKET, not on a selection change
     that can be polled for. That is fine and needs no event: the same record
     of what was on a field before this module replaced it, and the same rule
     that it is only ever written back while the field still shows this
     module's own string, covers it. Once the client has repainted, what is on
     screen is fresher than the record and the record is replaced.

Once bound, a field stays bound: these are stock frames that are reused for
every quest, so the walk runs until all three are found and then not again.

## Both panels, and what the turn-in one cannot do

Both the offer and the turn-in window get a flag row. They are the same
QuestFrame with a different panel showing, so one placer serves both and only
the anchor differs; each keeps its own buttons, bound fields and applied
signature, because both panels exist as frames at all times and one button
cannot be in two places.

Measured 2026-09-10 (questgivertextcomplete), the "Complete Quest" paragraph
comes from GetRewardText while GetQuestText and GetObjectiveText are empty.
The bundled locale rows have no completion-specific field, so this surface
uses the translated quest description for its localized paragraph and restores
the exact server completion text on the client's flag. Its measured reward
headings are translated from the addon catalog, reward item names through the
bundled per-language item tables, and the addon's experience/reputation rows
through their catalog entries in the same selected quest language.

## Naming the quest on the turn-in panel

That panel's packet carries only the title, and a title four quests share --
Executor Zygand offers four called "At War With The Scarlet Crusade" -- cannot
be broken by the two passes ResolveGiverQuestId normally uses, since both of
their inputs are empty here. It does not have to be: a quest being handed in is
already IN THE QUEST LOG, which carries the level and objective lines the packet
does not, and QuestState has already resolved that row. See
Match:ResolveLoggedQuestId in Data/QuestMatch.lua for why that route is refused
on the offer window.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local QuestGiverTranslation = UQ:NewModule("QuestGiverTranslation")

local POLL_INTERVAL = 0.2
local PARENT_NAME = "QuestFrame"

-- How far under the panel to look for the three body strings. Two levels of
-- child frames covers a panel that keeps its text directly and one that wraps
-- each block in a frame of its own, without turning the walk into a sweep of
-- the whole quest window.
local SEARCH_DEPTH = 2

-- Bound by content, in this order. `live` names the Client call that says what
-- the open window's own version of that field is -- the string a candidate
-- FontString has to be showing to BE that field.
local OFFER_FIELDS = {
    { field = "T", live = "GetQuestGiverTitle" },
    { field = "O", live = "GetQuestGiverObjective" },
    { field = "D", live = "GetQuestGiverDescription" },
}

-- The turn-in packet's paragraph is completion text (GetRewardText), while the
-- bundled locale row has no completion-specific field. The translated quest
-- description is used as the localized paragraph on this surface: it keeps
-- the whole quest readable when a language flag is selected, and returning to
-- the client's flag restores the exact completion text the server sent.
--
-- The remaining named fields were measured on 2026-09-10 by
-- questgivertextcomplete. Static reward headings come from the addon catalog;
-- reward item names are resolved through the bundled per-language item tables.
local COMPLETE_FIELDS = {
    { key = "T", field = "T", live = "GetQuestGiverTitle" },
    { key = "D", field = "D", live = "GetQuestCompletionText" },
    { key = "rewardHeading", name = "QuestRewardRewardTitleText",
        localeKey = "QUEST_COMPLETE_REWARDS" },
    { key = "choiceHeading", name = "QuestRewardItemChooseText",
        localeKey = "QUEST_COMPLETE_CHOOSE_REWARD" },
    { key = "receiveHeading", name = "QuestRewardItemReceiveText",
        localeKey = "QUEST_COMPLETE_RECEIVE_REWARD" },
}

local rewardIndex = 1
while rewardIndex <= 10 do
    table.insert(COMPLETE_FIELDS, {
        key = "rewardItem" .. tostring(rewardIndex),
        name = "QuestRewardItem" .. tostring(rewardIndex) .. "Name",
        itemName = true,
    })
    rewardIndex = rewardIndex + 1
end

-- The two panels of the one QuestFrame. Each keeps its own bound fields, its
-- own applied signature and its own flag buttons, because both exist at once
-- as frames and one button cannot be in two places.
local SURFACES = {
    {
        key = "questgiver",
        namePrefix = "UnrealQuestGiverLanguageFlag",
        panel = "GetQuestGiverDetailPanel",
        anchor = "GetQuestGiverDetailAnchor",
        fields = OFFER_FIELDS,
    },
    {
        key = "questcomplete",
        namePrefix = "UnrealQuestCompleteLanguageFlag",
        panel = "GetQuestCompleteDetailPanel",
        anchor = "GetQuestCompleteDetailAnchor",
        fields = COMPLETE_FIELDS,
    },
}

local function SurfaceState(surface)
    if not surface.state then
        surface.state = { bound = {}, appliedSignature = nil }
    end
    return surface.state
end

local function Translation()
    return UQ:GetModule("QuestLogTranslation")
end

local function LiveText(spec)
    local resolver = Client[spec.live]
    if type(resolver) ~= "function" then
        return nil
    end
    return resolver()
end

-- Finds whichever of the three fields is still unbound, by matching the live
-- strings against the FontStrings under the panel. Normalised through
-- UQ.NameKey on both sides, so wrapping, punctuation and case cannot make a
-- field that IS on screen look like one that is not.
local function BindFields(surface)
    local bound = SurfaceState(surface).bound
    local fields = surface.fields
    local wanted = {}
    local pending = 0
    local index = 1
    local total = table.getn(fields)
    while index <= total do
        local spec = fields[index]
        local fieldKey = spec.key or spec.field
        if not bound[fieldKey] and spec.name then
            bound[fieldKey] = Client.GetNamedObject(spec.name)
        elseif not bound[fieldKey] and spec.live then
            local key = UQ.NameKey(LiveText(spec))
            if key then
                wanted[fieldKey] = key
                pending = pending + 1
            end
        end
        index = index + 1
    end
    if pending == 0 then
        return bound
    end

    local resolvePanel = Client[surface.panel]
    local panel = type(resolvePanel) == "function" and resolvePanel() or nil
    if not panel then
        return bound
    end
    local strings = Client.CollectFontStrings(panel, SEARCH_DEPTH)
    if not strings then
        return bound
    end

    -- One object can only be one field. Objects already bound are off limits,
    -- and a candidate claimed by an earlier field in this pass is too.
    local claimed = {}
    index = 1
    while index <= total do
        local fieldKey = fields[index].key or fields[index].field
        local object = bound[fieldKey]
        if object then
            claimed[object] = true
        end
        index = index + 1
    end

    index = 1
    while index <= total do
        local fieldKey = fields[index].key or fields[index].field
        local key = wanted[fieldKey]
        if key then
            local candidate = 1
            local candidates = table.getn(strings)
            while candidate <= candidates and not bound[fieldKey] do
                local object = strings[candidate]
                if object and not claimed[object]
                    and UQ.NameKey(Client.GetObjectText(object)) == key then
                    -- Bound as the WRITABLE handle on that widget, not as the
                    -- wrapper the walk produced. Client.ResolveWritableObject
                    -- explains why they differ here; what matters at this end
                    -- is that a walked wrapper is a fresh object each pass, so
                    -- the native/applied bookkeeping hung on the fields below
                    -- would be written onto a throwaway. Content was still
                    -- verified on the object that was observed holding it, and
                    -- the exchange is by that object's own name.
                    bound[fieldKey] = Client.ResolveWritableObject(object)
                    claimed[object] = true
                end
                candidate = candidate + 1
            end
        end
        index = index + 1
    end
    return bound
end

-- Writes one field's remembered native text back, but only while that field is
-- still showing what this module put there -- the same rule, and for the same
-- reason, as Quest/QuestLogTranslation.lua's own restore.
local function RestoreField(spec, object)
    if not object then
        return true
    end
    local applied = object.unrealQuestGiverAppliedText
    if type(applied) ~= "string" then
        return true
    end
    if (Client.GetObjectText(object) or "") ~= applied then
        -- The client repainted; its text is the fresher answer and the record
        -- is stale by definition.
        object.unrealQuestGiverAppliedText = nil
        object.unrealQuestGiverNativeText = nil
        return true
    end
    -- Packet-backed fields can answer the server's exact text even if this
    -- module's snapshot was taken before the reusable completion panel had
    -- finished repainting for the new quest. Static headings and item labels
    -- have no such getter and retain their observed native snapshot.
    local native = LiveText(spec)
    if type(native) ~= "string" or native == "" then
        native = object.unrealQuestGiverNativeText
    end
    if type(native) ~= "string" then
        return false
    end
    if not Client.SetNativeObjectText(object, native) then
        -- Keep both records intact. Native completion widgets can be rewritten
        -- while the panel is settling; the next poll must be able to retry.
        return false
    end
    object.unrealQuestGiverAppliedText = nil
    object.unrealQuestGiverNativeText = native
    return true
end

local function RestoreNative(surface)
    local state = SurfaceState(surface)
    if not state.appliedSignature then
        return true
    end
    local fields = surface.fields
    local index = 1
    local total = table.getn(fields)
    local restored = true
    while index <= total do
        local spec = fields[index]
        if not RestoreField(spec, state.bound[spec.key or spec.field]) then
            restored = false
        end
        index = index + 1
    end
    if not restored then
        -- A successful field has already cleared its own applied marker; the
        -- signature keeps only the failed fields eligible for the next retry.
        return false
    end
    state.appliedSignature = nil
    local resolveAnchor = Client[surface.anchor]
    if type(resolveAnchor) == "function" then
        Client.UpdateScrollChildRect(resolveAnchor())
    end
    return true
end

local function ApplyField(database, quest, language, spec, object)
    if not object then
        return false
    end
    -- Normalised to a string: an empty field reads back as nil, and comparing
    -- nil against an unset record would decide the client's own text did not
    -- need recording -- leaving nothing to restore later.
    local currentText = Client.GetObjectText(object) or ""
    -- Anything that is not this module's own string is the client's own text,
    -- and it is what has to go back on a restore. Recorded here rather than on
    -- the first replacement, so a repaint between two polls updates the record
    -- instead of preserving a stale one.
    if currentText ~= object.unrealQuestGiverAppliedText then
        object.unrealQuestGiverNativeText = currentText
    end
    local nativeText = object.unrealQuestGiverNativeText
    local displayText = nil
    if spec.field then
        displayText = database:GetQuestDisplayText(quest, spec.field, nativeText)
    elseif spec.localeKey and UQ.LForLanguage then
        displayText = UQ.LForLanguage(language, spec.localeKey)
    elseif spec.itemName then
        displayText = database:GetItemDisplayNameForLanguage(nativeText, language)
    end
    if type(displayText) ~= "string" or displayText == "" then
        return false
    end
    if displayText == currentText then
        -- Already on screen: either this module wrote it on an earlier poll,
        -- or the desired translation survived a stock repaint.
        object.unrealQuestGiverAppliedText = displayText
        return true
    end
    if Client.SetNativeObjectText(object, displayText) then
        object.unrealQuestGiverAppliedText = displayText
        return true
    end
    return false
end

-- The quest the offer window is showing, as the shape every other surface
-- passes around: an ID plus the live title. Nil when the window is not up, or
-- when the three strings do not resolve to exactly one bundled quest.
-- The quest the given panel is showing, as the shape every other surface
-- passes around: an ID plus the live title. Nil when that panel is not up, or
-- when the packet does not resolve to exactly one bundled quest.
local function PanelQuest(surface)
    local frame = Client.GetNamedObject(PARENT_NAME)
    if not frame or not Client.IsObjectShown(frame) then
        return nil
    end
    local resolvePanel = Client[surface.panel]
    local panel = type(resolvePanel) == "function" and resolvePanel() or nil
    if not panel or not Client.IsObjectShown(panel) then
        return nil
    end
    -- Match:ResolveGiverQuestId answers for whichever panel is up: the offer
    -- window from the packet's own three strings, the turn-in window from the
    -- quest log, because the packet there carries only the title. See the note
    -- on ResolveLoggedQuestId in Data/QuestMatch.lua.
    local match = UQ:GetModule("QuestMatch")
    local questId = match and match:ResolveGiverQuestId()
    if type(questId) ~= "number" then
        return nil
    end
    return { questId = questId, title = Client.GetQuestGiverTitle() }
end

local function RefreshFlags(surface, quest)
    local flags = UQ:GetModule("QuestLanguageFlags")
    if not flags then
        return
    end
    local resolveAnchor = Client[surface.anchor]
    flags:Refresh({
        key = surface.key,
        namePrefix = surface.namePrefix,
        quest = quest,
        anchor = type(resolveAnchor) == "function" and resolveAnchor() or nil,
        -- One placer for both, because both panels live inside the same
        -- QuestFrame and that is the frame Client.PlaceQuestGiverFlag parents
        -- to; only the anchor differs.
        place = Client.PlaceQuestGiverFlag,
        translation = Translation(),
        onChanged = function()
            QuestGiverTranslation:Refresh()
            local rewards = UQ:GetModule("QuestLogRewards")
            if rewards then
                rewards:Refresh()
            end
        end,
    })
end

local function RefreshSurface(surface)
    local state = SurfaceState(surface)
    local quest = PanelQuest(surface)
    if not quest then
        -- Restore while the reusable stock panel is hidden too: its static
        -- reward headings may survive the panel swap even though packet-owned
        -- title/body/item strings are normally repainted by the client.
        RestoreNative(surface)
        RefreshFlags(surface, nil)
        return
    end

    RefreshFlags(surface, quest)

    local translation = Translation()
    local database = UQ:GetModule("Database")
    local clientLanguage = Client.GetLocale()
    local language = translation and translation:GetQuestLanguage(quest)
    if not database or type(language) ~= "string" or language == clientLanguage
        or not database:GetQuestTextForLanguage(quest.questId, language) then
        RestoreNative(surface)
        return
    end

    local signature = tostring(quest.questId) .. ":" .. language
    if state.appliedSignature and state.appliedSignature ~= signature then
        if not RestoreNative(surface) then
            return
        end
    end

    local bound = BindFields(surface)
    local fields = surface.fields
    local translated = 0
    local index = 1
    local total = table.getn(fields)
    while index <= total do
        local spec = fields[index]
        if ApplyField(database, quest, language, spec,
            bound[spec.key or spec.field]) then
            translated = translated + 1
        end
        index = index + 1
    end

    if translated > 0 then
        state.appliedSignature = signature
        local resolveAnchor = Client[surface.anchor]
        if type(resolveAnchor) == "function" then
            Client.UpdateScrollChildRect(resolveAnchor())
        end
    else
        state.appliedSignature = nil
    end
end

-- Both panels every pass. The one that is not on screen resolves no quest and
-- clears its own row, so a swap between offer and turn-in cannot leave the
-- other holding a stale flag -- the same rule Quest/QuestLogRewards.lua
-- follows for the reward rows on these two surfaces.
function QuestGiverTranslation:Refresh()
    local index = 1
    local total = table.getn(SURFACES)
    while index <= total do
        RefreshSurface(SURFACES[index])
        index = index + 1
    end
end

function QuestGiverTranslation:OnInit()
    UQ:DeclareCapability("questGiverTranslation", "unverified",
        "The offer window's three body strings are bound by matching GetTitleText, "
        .. "GetObjectiveText and GetQuestText against the FontStrings under "
        .. "QuestDetailScrollChildFrame, so nothing is written to an object not first "
        .. "observed holding that exact string. The 2026-09-10 questgivertext runs "
        .. "settled what was open here: the bodies are plain FontStrings named "
        .. "QuestTitleText, QuestObjectiveText and QuestDescription, not SimpleHTML, "
        .. "and they accept SetText through their globals. They do NOT accept it "
        .. "through the wrapper GetRegions returns, which is what made this feature "
        .. "silently do nothing; see Client.ResolveWritableObject. The turn-in panel "
        .. "is driven by the same code against QuestRewardScrollChildFrame; "
        .. "questgivertextcomplete measured its title, GetRewardText paragraph, "
        .. "reward headings and QuestRewardItem1..10Name fields. Since the bundled "
        .. "quest rows have no completion-specific text, the selected language uses "
        .. "the translated quest description there; reward items use the exact "
        .. "per-language item tables. Still unverified until the complete translated "
        .. "surface is confirmed in game")
end

function QuestGiverTranslation:OnEnable()
    local driver = UQ:GetModule("Driver")
    if not driver then
        return
    end
    driver:Schedule("questgiver.translation", POLL_INTERVAL, function()
        QuestGiverTranslation:Refresh()
    end)
end
