--[[
UnrealQuest / Quest/PfQuestImport.lua

Seeds Quest/QuestHistory.lua from pfQuest's own completed-quest history.

WHY THIS EXISTS. QuestHistory can only ever know about a quest it personally
watched leave the log complete, because this client has no quest ID API and no
completed-quest history call to ask (docs/CLIENT-COMPATIBILITY.md, "No quest ID
API"). A character who levelled with pfQuest installed therefore arrives here
with a blank slate, and every map "!" for a quest they finished years ago comes
back. pfQuest kept exactly the record this addon is missing, in a saved
variable of its own -- so on a machine where both addons are installed, the
answer is already on disk.

WHAT IS READ, AND WHAT IT MEANS.
  * `pfQuest_history` is one of pfQuest's SavedVariablesPerCharacter. Its keys
    are quest IDs and its values are { unixTime, playerLevel } -- pfQuest's
    config.lua MigrateHistory normalizes older shapes (a `true` value, or a
    quest TITLE as the key) into that form on load, and both older shapes are
    handled here too because a history written by an old pfQuest and never
    loaded by a new one still carries them.
  * The IDs are directly comparable to this addon's. Both databases are the
    same VMaNGOS data packaged by pfQuest (Database/CREDITS.md), so a quest ID
    in pfQuest's history names the same quest in `Database/quests.lua`. That is
    the one thing that makes this import possible at all rather than a title
    match, and it is checked rather than assumed: an ID the bundled data does
    not know (a TBC or WotLK quest, from a pfQuest-tbc install sharing the same
    global) is counted and skipped, never imported.
  * A TITLE key is resolved through the same normalized-title index quest log
    rows use (Data/Database.lua's FindQuestIdsByTitleKey). A title matching
    several quest IDs is ambiguous and is skipped, not guessed -- the addon's
    rule that a quest match is a hypothesis with a confidence applies here
    exactly as it does to a live quest log row.

WHAT THIS IS NOT. It is not evidence about the client, and it does not make
QuestHistory authoritative. It is one addon's record of what a character did,
copied into another addon's record of the same thing. Every quest it brings in
is filed in QuestHistory's IMPORTED provenance section, so the whole import
stays reversible as one act (`/uq pfquest undo`) without touching a single
completion this addon established for itself.

THE DISABLED CASE IS THE NORMAL CASE. Most players disable pfQuest the day
they install this addon, and a disabled addon's saved variables are never
loaded into memory. This client exposes no call to read an arbitrary file, so
with pfQuest off there is nothing in memory to read and nothing on disk this
addon can reach. That is not an edge case to apologize for -- it is what the
feature has to solve.

It is solved by borrowing pfQuest for exactly one reload:

  1. The player presses the button. pfQuest is installed but disabled, so this
     records what state it was in, calls EnableAddOn + SaveAddOns, and asks the
     player to type /reload. It cannot reload for them: ReloadUI is PROTECTED
     on this client ("addons cannot call this; only the default FrameXML UI
     can"), so the ask is the mechanism, not a shortcut.
  2. On the next load pfQuest's files run, its saved history appears as a
     global, and the pending flag left in this addon's per-character store
     tells ResumeAutoImport to look for it.
  3. The import runs by itself, pfQuest is put back exactly as it was found
     (DisableAddOn + SaveAddOns), and the flag is cleared. The player sees one
     line saying what came in.

Every step of that is reversible and none of it is silent. The restore runs
even when the import finds nothing, and even when the history never appears --
a flag that outlives its reload restores the addon state and gives up rather
than leaving pfQuest switched on behind the player's back.

TWO STRUCTURAL LIMITS, both stated to the player rather than papered over:
  * A pending enable does not take effect until the UI reloads. Nothing here
    pretends an enabled-this-second addon's saved variables are readable now.
  * An absent global cannot be distinguished from an empty history, so the
    player-facing text says "not loaded", never "you have none".

The history is PER CHARACTER on both sides, and now genuinely so: the quest
completion record moved to `## SavedVariablesPerCharacter` (Core/Config.lua's
CHARACTER_SECTIONS) so importing one character's pfQuest history cannot mark
quests done for an alt that never did them.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local PfQuestImport = UQ:NewModule("PfQuestImport")

-- pfQuest, pfQuest-tbc and pfQuest-wotlk all declare this same global, so one
-- name covers every variant the player might have installed.
local SOURCE_GLOBAL = "pfQuest_history"

-- The addon folders that declare it, most likely first. Only one of them is
-- ever installed in practice; the list exists so a player running the TBC or
-- WotLK build is not told pfQuest is missing.
local ADDON_NAMES = { "pfQuest", "pfQuest-tbc", "pfQuest-wotlk" }

local CAPABILITY = "pfQuestHistoryImport"

-- Per-character scalars carrying an auto-enable across the reload it needs.
-- PENDING_KEY holds the addon folder that was switched on, which is also the
-- "an import is waiting for this reload" flag; RESTORE_KEY records whether it
-- has to be switched off again afterwards.
local PENDING_KEY = "pfQuestAutoImport"
local RESTORE_KEY = "pfQuestAutoImportDisable"

-- The resume poll. pfQuest's files and this addon's OnEnable are not ordered
-- with respect to each other by anything measured, so the resume LOOKS on a
-- timer instead of assuming -- and gives up after a bounded window rather than
-- polling for the rest of the session.
local RESUME_JOB = "pfquest.autoimport"
local RESUME_INTERVAL = 1
local RESUME_SECONDS = 20

local function Config()
    return UQ:GetModule("Config")
end

local function Database()
    return UQ:GetModule("Database")
end

local function History()
    return UQ:GetModule("QuestHistory")
end

-- Both map layers cache the "done" set in their view signature, so an import
-- that changes it has to say so or the map keeps drawing the "!" markers it
-- already decided on.
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

-- Reads the source table, or nil. Re-read on every scan rather than cached at
-- load: nothing establishes the order in which this client loads two addons'
-- saved variables, so a global that was absent when UnrealQuest started may be
-- present by the time the player opens the options page.
function PfQuestImport:GetSource()
    return Client.GetSavedVariableTable(SOURCE_GLOBAL)
end

-- Turns one pfQuest history entry into a quest ID this addon's data knows, or
-- nil plus the reason it could not.
--
-- Reasons are the vocabulary the report is built from:
--   "unknown"    a numeric ID the bundled Vanilla data does not carry
--   "unmatched"  a title key no quest in the data matches
--   "ambiguous"  a title key several quests share
--   "waiting"    a title key that cannot be resolved yet, because the title
--                index is still building (Database:IndexChunk)
local function ResolveEntry(key)
    local database = Database()
    if not database then
        return nil, "unknown"
    end

    if type(key) == "number" then
        if database:GetQuest(key) then
            return key, nil
        end
        return nil, "unknown"
    end

    if type(key) ~= "string" then
        return nil, "unknown"
    end

    local titleKey = UQ.NameKey(key)
    if not titleKey then
        return nil, "unmatched"
    end
    if not database:IsIndexReady() then
        return nil, "waiting"
    end
    local candidates = database:FindQuestIdsByTitleKey(titleKey)
    if not candidates or table.getn(candidates) == 0 then
        return nil, "unmatched"
    end
    if table.getn(candidates) > 1 then
        return nil, "ambiguous"
    end
    return candidates[1], nil
end

-- pfQuest writes { time, level } for a completed quest. Anything else is read
-- conservatively: a `true` value is the pre-migration shape and still means
-- done, but a `false` or a nil is not a completion and is not imported.
local function IsCompletion(value)
    if value == true then
        return true
    end
    if type(value) == "table" then
        return true
    end
    return false
end

-- Which pfQuest variant is installed, and what state it is in. Returns nil
-- when none of them is in the addon registry at all -- which is a different
-- answer from "installed but off", and the two lead to completely different
-- player-facing text.
function PfQuestImport:FindAddOn()
    local index = 1
    local total = table.getn(ADDON_NAMES)
    while index <= total do
        local name = ADDON_NAMES[index]
        if Client.IsAddOnInstalled(name) then
            return name, Client.IsAddOnEnabled(name), Client.IsAddOnLoaded(name)
        end
        index = index + 1
    end
    return nil
end

-- The whole situation in one table, so the options page, the slash command and
-- the button all branch on the same reading rather than three of their own.
--
-- `state` is the single word the callers switch on:
--   "ready"        the history is in memory; an import can run right now
--   "pending"      pfQuest was switched on and the reload has not happened yet
--   "disabled"     installed but off; pressing the button starts the flow
--   "unavailable"  enabled but its files have not run yet, so a reload is all
--                  that is missing
--   "empty"        enabled, loaded, and it simply has no history for this
--                  character -- a reload would change nothing, so the button
--                  must not offer one
--   "missing"      not installed at all; nothing to import from, ever
function PfQuestImport:GetState()
    local status = {
        source = self:GetSource(),
        addon = nil,
        enabled = nil,
        loaded = nil,
        pending = nil,
        state = "missing",
    }

    local config = Config()
    if config then
        local pending = config:GetCharacter(PENDING_KEY)
        if type(pending) == "string" and pending ~= "" then
            status.pending = pending
        end
    end

    status.addon, status.enabled, status.loaded = self:FindAddOn()

    if status.source then
        status.state = "ready"
    elseif status.pending then
        status.state = "pending"
    elseif not status.addon then
        status.state = "missing"
    elseif status.enabled == false then
        status.state = "disabled"
    elseif status.loaded == true then
        status.state = "empty"
    else
        status.state = "unavailable"
    end
    return status
end

-- Switches pfQuest on for one reload and remembers to switch it back off.
--
-- Returns the word the caller reports: "ready" (nothing to do, the data is
-- already here), "asked" (flipped; the player now has to type /reload),
-- "pending" (already flipped by an earlier press), "refused" (the client would
-- not take the change), or "missing".
--
-- The state to restore is written BEFORE the flag is flipped. If anything goes
-- wrong between the two, the worst case is a restore that finds nothing to do
-- -- never a pfQuest left enabled with no record that this addon enabled it.
function PfQuestImport:BeginAutoEnable()
    local status = self:GetState()
    if status.state == "ready" then
        return "ready", status
    end
    if status.state == "pending" then
        return "pending", status
    end
    if not status.addon then
        return "missing", status
    end
    -- Loaded, and it still has no history: there is nothing a reload would
    -- load that is not already here, so do not ask for one.
    if status.state == "empty" then
        return "empty", status
    end

    local config = Config()
    if not config then
        return "refused", status
    end

    -- Enabled already and still no history: a reload is all that is missing,
    -- and nothing has to be put back afterwards.
    local mustDisable = status.enabled == false

    config:SetCharacter(RESTORE_KEY, mustDisable)
    config:SetCharacter(PENDING_KEY, status.addon)

    if mustDisable and not Client.SetAddOnEnabled(status.addon, true) then
        config:SetCharacter(PENDING_KEY, nil)
        config:SetCharacter(RESTORE_KEY, nil)
        return "refused", status
    end

    return "asked", status
end

-- Puts pfQuest back exactly as it was found and clears the flags. Called on
-- every exit from the resumed flow -- success, empty history, or timeout --
-- because the one outcome that must never happen is the player being left with
-- an addon this code switched on and forgot about.
function PfQuestImport:RestoreAddOnState()
    local config = Config()
    if not config then
        return false
    end
    local addon = config:GetCharacter(PENDING_KEY)
    local mustDisable = config:GetCharacter(RESTORE_KEY)
    config:SetCharacter(PENDING_KEY, nil)
    config:SetCharacter(RESTORE_KEY, nil)

    if type(addon) ~= "string" or addon == "" or not mustDisable then
        return false
    end
    return Client.SetAddOnEnabled(addon, false)
end

-- What an import would do, without doing any of it. Also what the options page
-- and `/uq pfquest` report, so the count the player is shown and the count the
-- button acts on come from the same pass over the same data.
--
-- Returns a table; `found` is false when pfQuest's global is not loaded at all,
-- and every count is zero in that case.
function PfQuestImport:Scan()
    local report = {
        found = false,
        entries = 0,
        importable = 0,
        alreadyDone = 0,
        unknown = 0,
        unmatched = 0,
        ambiguous = 0,
        waiting = 0,
        ids = {},
    }

    local source = self:GetSource()
    if not source then
        self:DeclareState(report)
        return report
    end
    report.found = true

    local history = History()
    local key, value
    for key, value in pairs(source) do
        if IsCompletion(value) then
            report.entries = report.entries + 1
            local questId, reason = ResolveEntry(key)
            if questId then
                if history and history:IsDone(questId) then
                    report.alreadyDone = report.alreadyDone + 1
                else
                    report.importable = report.importable + 1
                    table.insert(report.ids, questId)
                end
            elseif reason == "ambiguous" then
                report.ambiguous = report.ambiguous + 1
            elseif reason == "unmatched" then
                report.unmatched = report.unmatched + 1
            elseif reason == "waiting" then
                report.waiting = report.waiting + 1
            else
                report.unknown = report.unknown + 1
            end
        end
    end

    self:DeclareState(report)
    return report
end

-- Marks everything the scan found importable, and returns the same report with
-- an `imported` count added. Re-scans rather than taking a caller's report: the
-- player may have opened the page minutes ago, and marking a quest done twice
-- is harmless but reporting a stale number is not.
function PfQuestImport:Import()
    local report = self:Scan()
    report.imported = 0

    local history = History()
    if not history then
        return report
    end

    local index = 1
    local total = table.getn(report.ids)
    while index <= total do
        if history:MarkDoneImported(report.ids[index]) then
            report.imported = report.imported + 1
        end
        index = index + 1
    end

    if report.imported > 0 then
        MarkMapDirty()
    end
    return report
end

-- Takes back every quest a previous import brought in. Completions this addon
-- established on its own, and quests the player marked by hand, are untouched.
function PfQuestImport:Undo()
    local history = History()
    if not history then
        return 0
    end
    local reset = history:ResetImported()
    local total = table.getn(reset)
    if total > 0 then
        MarkMapDirty()
    end
    return total
end

-- ONE LINE, for the options page. Never more than about 80 characters, because
-- the page reserves a single body line for it and cannot re-measure the line
-- after a rewrite (Core/Settings.lua, page.Body's reservedLines) -- a longer
-- string would wrap into the button underneath it.
--
-- The page gets the headline and `/uq pfquest` gets the breakdown, which is
-- the right split anyway: the page answers "is there anything to do here", and
-- a player who wants to know why 12 quests were skipped is already the kind of
-- player who will type the command.
function PfQuestImport:DescribeShort(report)
    report = report or self:Scan()

    if report.found then
        if report.entries == 0 then
            return "pfQuest is loaded, but its history for this character is empty."
        end
        if report.importable > 0 then
            return tostring(report.importable)
                .. " quest(s) in pfQuest's history are ready to import."
        end
        return "pfQuest's history holds nothing this addon has not already recorded."
    end

    local status = self:GetState()
    if status.state == "pending" then
        return "pfQuest is on for one reload -- type /reload to run the import."
    end
    if status.state == "disabled" then
        return "pfQuest is installed but disabled -- the button borrows it for one reload."
    end
    if status.state == "missing" then
        return "pfQuest is not installed, so there is no saved history to import."
    end
    if status.state == "empty" then
        return "pfQuest is loaded but has recorded no completed quests here."
    end
    return "pfQuest is enabled but has written no history for this character yet."
end

-- The full breakdown, for `/uq pfquest` and for the line printed after a
-- press. Several sentences is fine here -- chat wraps and scrolls, and this is
-- where a player goes to find out WHY a count is what it is.
function PfQuestImport:Describe(report)
    report = report or self:Scan()

    if not report.found then
        local status = self:GetState()
        if status.state == "pending" then
            return "pfQuest has been switched on for one reload. Type /reload and the "
                .. "import runs by itself, then switches it off again."
        end
        if status.state == "disabled" then
            return "pfQuest is installed but disabled, so its saved history is not in "
                .. "memory. The button switches it on for one reload, imports, and "
                .. "switches it back off."
        end
        if status.state == "missing" then
            return "pfQuest is not installed, so there is no saved history to import from."
        end
        if status.state == "empty" then
            return "pfQuest is loaded but has recorded no completed quests for this "
                .. "character, so there is nothing to import."
        end
        return "pfQuest is enabled but its files have not run yet -- type /reload."
    end

    if report.entries == 0 then
        return "pfQuest is loaded, but its history for this character is empty."
    end

    local text = tostring(report.entries) .. " completed in pfQuest's history: "
        .. tostring(report.importable) .. " to import, "
        .. tostring(report.alreadyDone) .. " already here."
    if report.waiting > 0 then
        text = text .. " " .. tostring(report.waiting) .. " waiting on the title index."
    end
    local skipped = report.unknown + report.unmatched + report.ambiguous
    if skipped > 0 then
        text = text .. " " .. tostring(skipped)
            .. " skipped (not in this client's quest data, or an ambiguous title)."
    end

    local history = History()
    local imported = history and history:GetImportedCount() or 0
    if imported > 0 then
        text = text .. " " .. tostring(imported) .. " imported previously."
    end
    return text
end

-- What the options page's single button should say right now. The button does
-- whatever the situation needs (see :Press), so its label is the only thing
-- telling the player which of those it is about to do -- a button reading
-- "Import from pfQuest" that actually enables an addon and asks for a reload
-- would be lying about a change to their addon list.
function PfQuestImport:GetButtonLabel()
    local state = self:GetState().state
    if state == "ready" then
        return "Import from pfQuest"
    end
    if state == "pending" then
        return "Waiting for /reload"
    end
    if state == "missing" then
        return "pfQuest not installed"
    end
    if state == "empty" then
        return "pfQuest has no history"
    end
    return "Enable pfQuest and import"
end

-- The one action behind the options-page button and `/uq pfquest import`.
-- Chooses by state so both surfaces behave identically, and reports what it
-- did in chat -- including the two cases where the answer is "nothing yet, and
-- here is what you have to do".
--
-- Returns the state word it acted on, for callers that want to branch further.
function PfQuestImport:Press()
    local status = self:GetState()

    if status.state == "missing" then
        UQ:Print("pfQuest is not installed, so there is no saved history to import")
        return status.state
    end

    if status.state == "empty" then
        UQ:Print("pfQuest is loaded but has recorded no completed quests for this character, "
            .. "so there is nothing to import")
        return status.state
    end

    if status.state == "ready" then
        local report = self:Import()
        if report.imported > 0 then
            UQ:Print("imported " .. report.imported
                .. " completed quest(s) from pfQuest -- /uq pfquest undo takes them back")
        else
            UQ:Print("nothing new to import: " .. self:Describe(report))
        end
        return status.state
    end

    if status.state == "pending" then
        UQ:Print("pfQuest is already switched on for the import -- type /reload to run it")
        return status.state
    end

    local outcome = self:BeginAutoEnable()
    if outcome == "refused" then
        UQ:Print("the client would not change pfQuest's enabled state; enable pfQuest "
            .. "in the addon list yourself and press this again")
    elseif outcome == "asked" then
        UQ:Print("pfQuest has been switched on for one reload")
        UQ:Print("  type /reload -- the import runs by itself, then switches pfQuest back off")
    end
    return status.state
end

-- The capability is re-declared on every scan rather than fixed at load,
-- because whether pfQuest's data is reachable is a fact about the player's
-- install that can only be observed by looking -- and looking is what a scan
-- does. `detected` means the global was actually found this session.
function PfQuestImport:DeclareState(report)
    if report and report.found then
        UQ:DeclareCapability(CAPABILITY, "detected",
            "pfQuest's " .. SOURCE_GLOBAL .. " saved variable is loaded and readable; "
            .. tostring(report.entries) .. " completed quest(s) in it, "
            .. tostring(report.importable) .. " importable into this addon's quest history")
        return
    end

    -- Not loaded is several different situations, and /uq status is the place
    -- a player looks to find out WHICH -- "you never had pfQuest" and "your
    -- pfQuest is one command away" must not print the same row.
    local status = self:GetState()
    local note = "pfQuest's " .. SOURCE_GLOBAL .. " saved variable is not loaded. It is a "
        .. "SavedVariablesPerCharacter of the pfQuest addon, so it is in memory only while "
        .. "pfQuest is enabled -- this client offers no way to read the file otherwise, so "
        .. "an absent global cannot be told apart from an empty history. "

    if status.state == "pending" then
        note = note .. "pfQuest has been switched on for one reload and the import is "
            .. "waiting for it; type /reload. ReloadUI is protected here, so the addon "
            .. "cannot do that step for the player"
    elseif status.state == "disabled" then
        note = note .. "pfQuest (" .. tostring(status.addon) .. ") IS installed, just "
            .. "disabled: /uq pfquest import switches it on for one reload, imports, and "
            .. "switches it back off"
    elseif status.state == "missing" then
        note = note .. "no pfQuest variant is installed, so there is nothing to import from"
    elseif status.state == "empty" then
        note = note .. "pfQuest (" .. tostring(status.addon) .. ") is enabled and loaded and "
            .. "has simply recorded no completed quests for this character; a reload would "
            .. "not change that, so nothing offers one"
    else
        note = note .. "pfQuest (" .. tostring(status.addon) .. ") is enabled but its files "
            .. "have not run yet; a reload is all that is missing"
    end

    UQ:DeclareCapability(CAPABILITY, "missing", note)
end

-- The second half of the auto-enable flow, running on the load after the
-- player typed /reload.
--
-- A POLL, not an event and not a one-shot read: nothing measured orders
-- pfQuest's files against this addon's OnEnable, so this looks once a second
-- until the history appears or the window closes. Either way it ends by
-- restoring pfQuest's enabled state and unscheduling itself -- there is no
-- path out of here that leaves the job running or the flag set.
function PfQuestImport:ResumeAutoImport()
    local driver = UQ:GetModule("Driver")
    -- Returns whether pfQuest was actually switched back off, so the player is
    -- only told that when it happened.
    local function Finish()
        local restored = self:RestoreAddOnState()
        if driver then
            driver:Unschedule(RESUME_JOB)
        end
        return restored
    end

    if self:GetSource() then
        local report = self:Import()
        local restored = Finish()
        if report.imported > 0 then
            UQ:Print("imported " .. report.imported
                .. " completed quest(s) from pfQuest -- /uq pfquest undo takes them back")
        else
            UQ:Print("pfQuest's history had nothing new to import")
        end
        if restored then
            UQ:Print("  pfQuest has been switched back off, as it was before")
        end
        return
    end

    self.resumeWaited = (self.resumeWaited or 0) + RESUME_INTERVAL
    if self.resumeWaited < RESUME_SECONDS then
        return
    end

    Finish()
    UQ:Print("pfQuest was switched on for the import but its history never appeared; "
        .. "nothing was imported and pfQuest has been put back as it was")
end

-- One look at enable, so `/uq status` has an honest row before the player ever
-- opens the options page (Scan declares the capability itself). This is a look,
-- not a dependency: nothing here registers an event or waits for pfQuest, and
-- every later scan re-declares the row from what it finds then -- which is the
-- part that matters, since a global that was absent at enable may be there by
-- the time the player asks.
--
-- The one job it may schedule is the resume, and only when a flag left by a
-- previous session says an import is waiting for this reload.
function PfQuestImport:OnEnable()
    self:Scan()

    local config = Config()
    local pending = config and config:GetCharacter(PENDING_KEY)
    if type(pending) ~= "string" or pending == "" then
        return
    end

    self.resumeWaited = 0
    local driver = UQ:GetModule("Driver")
    if not driver then
        -- No driver means no poll and no second chance, so take the one look
        -- available and put pfQuest back either way.
        self:ResumeAutoImport()
        return
    end
    driver:Schedule(RESUME_JOB, RESUME_INTERVAL, function()
        PfQuestImport:ResumeAutoImport()
    end)
end
