--[[
UnrealQuest / Core/Locale.lua

The translation layer: a key -> text lookup with a fixed English fallback, and
the language selection that drives it.

This is deliberately not a locale framework. There is no runtime string
extraction and no per-module registry: Locales/*.lua each register one flat
table, every player-facing string is fetched through UQ.L where it is used, and
the selected language is one four-letter code in the account config store.

WHERE THE LANGUAGE COMES FROM, AND WHY IT IS RESOLVED THE SAME WAY THE OPTIONS
PAGE RESOLVES ITS HOST.

  * unrealUI installed -> UnrealQuest follows unrealUI's language. One player
    setting for both addons; UnrealQuest shows no flag selector of its own,
    exactly as it shows no minimap button of its own when unrealUI is there.
  * unrealUI absent -> UnrealQuest's own stored language, picked with the flag
    row in the top-right of its own settings window.

Neither case is a dependency. unrealUI is read through two type-checked lookups
and nothing else, this addon declares no dependency on it, and every step falls
back to the stored language, so a standalone install and an install where
unrealUI failed behave identically.

Detection is a POLL, not a load-order assumption and not an event -- the same
three reasons Core/Settings.lua gives: UnrealQuest.toc declares no dependency
and the client's TOC dependency fields have no record in the compatibility
database, IsAddOnLoaded is DOCUMENTED_NOT_RUNTIME_VERIFIED and answers "files
loaded" rather than "the API exists", and ADDON_LOADED has no probed record
here so no event may be the mechanism.

TWO WAYS TO ASK UNREALUI, AND WHY BOTH ARE NEEDED.

  1. UnrealUI.GetLanguage(), once UnrealUI.ready is true. That flag is set
     after unrealUI's own Initialise has run its LoadLanguage, so before it the
     getter still answers with unrealUI's compiled-in default rather than the
     player's choice. Reading it early would silently latch English.
  2. UnrealUIProfiles.language, the account-wide value unrealUI persists.
     A SavedVariables global is loaded by the client's own reader before addon
     files run (see Client.GetSavedVariableTable's note), so this is readable
     at VARIABLES_LOADED -- which is when this addon initializes and,
     critically, before any UnrealQuest label has been built. It is validated
     against the known codes, never trusted as a key.

(2) is what makes the common case correct on the first frame; (1) is the
authoritative answer and the one the poll waits for. They agree in practice --
(2) is where (1) reads from.

A label is translated ONCE, when it is built, and never re-read. Nothing in
this addon may call UQ.L at file scope: at file-load time the language is not
known yet, so every such lookup would answer in English for the whole session.
A file-scope table of strings (a tooltip's shortcut list, a menu's category
labels) therefore stores KEYS and resolves them at use.

knowledge.json / config.savedvariables_backslash_corruption: the stored value
is a four-letter code, validated against the known list before it is used, so a
mangled or hand-edited saved file falls back to English rather than reaching a
lookup as a corrupt key. Flag texture paths carry backslashes and are rebuilt
at runtime here, never persisted.

knowledge.json / fonts.setfont_silent_failure: addon-bundled TTFs do not load
on this client, so every translated string is drawn by the inherited native
font object. Whether Cyrillic and CJK glyphs render at all is a property of the
client's own font and is not something this addon can fix by shipping one. The
selector stays usable in every language because its choices are flags, with an
ASCII two-letter badge as the fallback, so a player who sees missing glyphs can
always find the way back.

Encoding: Locales/*.lua are UTF-8 without a BOM, and the string type here is
byte-oriented UTF-8. Never use string.len or string.sub to trim a translated
string for display -- on any non-ASCII language that cuts a multi-byte
character in half. UQ.NameKey (Core/Namespace.lua) documents the same trap for
string.lower and the %a/%d/%u pattern classes.
]]

local UQ = UnrealQuest
local Client = UQ.Client
local Locale = UQ:NewModule("Locale")

local DEFAULT_LANGUAGE = "enUS"

-- How long to keep looking for unrealUI before committing to this addon's own
-- stored language. The same interval and grace period Core/Settings.lua uses
-- for host resolution, for the same reason: it is a once-per-session decision
-- and the job costs two global reads every half second until it is made.
local POLL_INTERVAL = 0.5
local POLL_SECONDS = 15

-- Ordered for the flag row in the standalone settings window. The order is
-- unrealUI's own, so a player with both addons sees the same four flags in the
-- same places. `short` is the two-letter badge drawn when the artwork is
-- unavailable; `label` is the language's own name, which is what a player
-- looking for their language scans for. `flag` is a FILE STEM, not a path --
-- the path is rebuilt in UQ.FlagTexture and never stored.
--
-- "Francais" is spelt without its cedilla on purpose: the client's font draws
-- the ASCII range and little else, so an accented Latin glyph comes out blank
-- (fonts.setfont_silent_failure). The whole French catalog is folded the same
-- way -- see ascii_fold in tools/locale/gen_locales.py. Chinese and Russian
-- are not foldable and are exactly why the flags exist beside the labels.
UQ.languages = {
    { code = "enUS", short = "EN", label = "English",  flag = "en" },
    { code = "zhCN", short = "CN", label = "简体中文", flag = "cn" },
    { code = "ruRU", short = "RU", label = "Русский",  flag = "ru" },
    { code = "frFR", short = "FR", label = "Francais", flag = "fr" },
}

local languageByCode = {}
do
    local index = 1
    local total = table.getn(UQ.languages)
    while index <= total do
        local entry = UQ.languages[index]
        entry.index = index
        languageByCode[entry.code] = entry
        index = index + 1
    end
end

-- code -> { key = text }. Locales/*.lua fill these at file load; nothing here
-- runs before they do.
local strings = {}
-- code -> function(n) -> plural form name. Only a language whose plural rules
-- differ from English needs to register one.
local plurals = {}

local active = DEFAULT_LANGUAGE
local activeStrings
local fallbackStrings

local function Activate(code)
    active = code
    activeStrings = strings[code]
    fallbackStrings = strings[DEFAULT_LANGUAGE]
end

-- Registration ---------------------------------------------------------------

-- Called once per file in Locales/. Merging rather than assigning means a
-- language can be split across several files later without changing callers.
function UQ.RegisterLocale(code, entries)
    if not languageByCode[code] then
        UQ:Warn("unknown locale: " .. tostring(code))
        return
    end
    if type(entries) ~= "table" then
        return
    end

    local target = strings[code]
    if not target then
        target = {}
        strings[code] = target
    end

    for key, text in pairs(entries) do
        if type(key) == "string" and type(text) == "string" then
            target[key] = text
        end
    end

    if code == DEFAULT_LANGUAGE then
        fallbackStrings = target
    end
    if code == active then
        activeStrings = target
    end
end

-- selector(n) must return one of the form names used as a key suffix: "ONE",
-- "FEW", "MANY" or "OTHER". A language without one gets the English rule.
function UQ.RegisterLocalePlural(code, selector)
    if languageByCode[code] and type(selector) == "function" then
        plurals[code] = selector
    end
end

local function EnglishPlural(n)
    if n == 1 then
        return "ONE"
    end
    return "OTHER"
end

-- Lookup ---------------------------------------------------------------------

-- A missing key returns the key itself. That is deliberate: an untranslated
-- string then shows up in game as a visible upper-case identifier instead of
-- an empty label, which is the failure mode that is actually findable.
local function Resolve(key)
    if type(key) ~= "string" then
        return ""
    end
    if activeStrings then
        local text = activeStrings[key]
        if text then
            return text
        end
    end
    if fallbackStrings then
        local text = fallbackStrings[key]
        if text then
            return text
        end
    end
    return key
end

-- UQ.L("KEY")       -> the translated string
-- UQ.L("KEY", a, b) -> string.format of it with those arguments
--
-- The format call is guarded because the pattern comes from a translation
-- file: a translator dropping a %s must not take a settings page or a tooltip
-- down with it. On a bad pattern the unformatted string is shown, which is
-- wrong but legible.
function UQ.L(key, a, b, c, d)
    local text = Resolve(key)
    if a == nil then
        return text
    end
    local ok, formatted = pcall(string.format, text, a, b, c, d)
    if ok and type(formatted) == "string" then
        return formatted
    end
    return text
end

-- Resolve one interface string in an explicitly named language without
-- changing the account-wide interface language. Quest-panel language flags
-- use this for labels that belong to one translated quest (for example its
-- reward summary), while every ordinary addon label continues to use UQ.L.
function UQ.LForLanguage(language, key, a, b, c, d)
    local text = nil
    if type(language) == "string" and type(strings[language]) == "table" then
        text = strings[language][key]
    end
    if not text and fallbackStrings then
        text = fallbackStrings[key]
    end
    if not text then
        text = type(key) == "string" and key or ""
    end
    if a == nil then
        return text
    end
    local ok, formatted = pcall(string.format, text, a, b, c, d)
    if ok and type(formatted) == "string" then
        return formatted
    end
    return text
end

-- Plural form of a counted string. The catalog holds one key per form,
-- suffixed "_ONE" / "_FEW" / "_MANY" / "_OTHER"; only the forms a language
-- actually uses need to exist, and the count is passed to the format as %d.
function UQ.LN(key, n, a, b)
    local count = tonumber(n) or 0
    local selector = plurals[active] or EnglishPlural
    local ok, form = pcall(selector, count)
    if not ok or type(form) ~= "string" then
        form = EnglishPlural(count)
    end

    -- Fall through to the general form before giving up, so a language that
    -- defines only _OTHER still renders instead of showing a raw key.
    local suffixed = key .. "_" .. form
    if Resolve(suffixed) == suffixed then
        suffixed = key .. "_OTHER"
    end

    if a == nil then
        return UQ.L(suffixed, count)
    end
    return UQ.L(suffixed, count, a, b)
end

-- Database text is not generated through tools/locale/gen_locales.py, so a
-- French quest title selected for an addon-owned surface would otherwise keep
-- glyphs this client's inherited font draws as blanks. This is the runtime
-- counterpart of the generator's ASCII fold, applied only to newly translated
-- database text. Client-provided titles are never rewritten.
--
-- Byte escapes keep this source English-only and make every replacement exact
-- in the client's byte-oriented Lua strings. Multi-character punctuation
-- pairs come first so French guillemet spacing is removed with the marks.
local FRENCH_GAME_TEXT_FOLD = {
    { "\194\171 ", "\"" }, { " \194\187", "\"" },
    { "\195\160", "a" }, { "\195\161", "a" }, { "\195\162", "a" },
    { "\195\163", "a" }, { "\195\164", "a" }, { "\195\165", "a" },
    { "\195\167", "c" },
    { "\195\168", "e" }, { "\195\169", "e" }, { "\195\170", "e" },
    { "\195\171", "e" },
    { "\195\172", "i" }, { "\195\173", "i" }, { "\195\174", "i" },
    { "\195\175", "i" }, { "\195\177", "n" },
    { "\195\178", "o" }, { "\195\179", "o" }, { "\195\180", "o" },
    { "\195\181", "o" }, { "\195\182", "o" },
    { "\195\185", "u" }, { "\195\186", "u" }, { "\195\187", "u" },
    { "\195\188", "u" }, { "\195\189", "y" }, { "\195\191", "y" },
    { "\195\128", "A" }, { "\195\129", "A" }, { "\195\130", "A" },
    { "\195\131", "A" }, { "\195\132", "A" }, { "\195\133", "A" },
    { "\195\135", "C" },
    { "\195\136", "E" }, { "\195\137", "E" }, { "\195\138", "E" },
    { "\195\139", "E" },
    { "\195\140", "I" }, { "\195\141", "I" }, { "\195\142", "I" },
    { "\195\143", "I" }, { "\195\145", "N" },
    { "\195\146", "O" }, { "\195\147", "O" }, { "\195\148", "O" },
    { "\195\149", "O" }, { "\195\150", "O" },
    { "\195\153", "U" }, { "\195\154", "U" }, { "\195\155", "U" },
    { "\195\156", "U" }, { "\195\157", "Y" },
    { "\197\147", "oe" }, { "\197\146", "OE" },
    { "\195\166", "ae" }, { "\195\134", "AE" }, { "\195\159", "ss" },
    { "\194\171", "\"" }, { "\194\187", "\"" },
    { "\226\128\152", "'" }, { "\226\128\153", "'" },
    { "\226\128\156", "\"" }, { "\226\128\157", "\"" },
    { "\226\128\147", "-" }, { "\226\128\148", "--" },
    { "\226\128\166", "..." }, { "\194\160", " " },
}

function UQ.PrepareTranslatedGameText(text, language)
    if type(text) ~= "string" or language ~= "frFR" then
        return text
    end
    local folded = text
    local index = 1
    local total = table.getn(FRENCH_GAME_TEXT_FOLD)
    while index <= total do
        local replacement = FRENCH_GAME_TEXT_FOLD[index]
        folded = string.gsub(folded, replacement[1], replacement[2])
        index = index + 1
    end
    return folded
end

-- Selection ------------------------------------------------------------------

function UQ.GetLanguages()
    return UQ.languages
end

function UQ.GetLanguage()
    return active
end

function UQ.GetLanguageLabel(code)
    local entry = languageByCode[code or active]
    return entry and entry.label or tostring(code)
end

-- The two-letter badge drawn where the flag artwork will not load.
function UQ.GetLanguageBadge(code)
    local entry = languageByCode[code or active]
    return entry and entry.short or "?"
end

function UQ.IsValidLanguage(code)
    return languageByCode[code] ~= nil
end

-- Rebuilt on every call and never persisted: the path carries backslashes and
-- a stored one can lose its separators through this client's SavedVariables
-- writer. A code without artwork returns nil, and the caller draws the ASCII
-- badge instead.
function UQ.FlagTexture(code)
    local entry = languageByCode[code]
    if not entry or type(entry.flag) ~= "string" then
        return nil
    end
    return "Interface\\AddOns\\unrealQuest\\media\\Flags\\" .. entry.flag
end

-- Per-quest exceptions to the language ---------------------------------------
--
-- The language above is one account-wide choice. This is the exception list
-- beside it: quests the player asked to read in a different language, chosen
-- with the flag in the quest log detail pane's top-right corner
-- (Quest/QuestLogButtons.lua). The value is a LANGUAGE CODE, not a yes/no --
-- the flag cycles through the languages that quest actually has, and the
-- client's own locale is one of them, meaning "the text the server sent".
-- No entry follows the account-wide setting.
--
-- The scope is the QUEST, not the quest log: Database:GetQuestDisplayText is
-- the single title policy every surface goes through, so an overridden quest
-- reads the same way in the tracker, on the map and in tooltips as it does in
-- the log. That is what "only this quest" means here -- one quest everywhere,
-- not one panel.
--
-- Deliberately NOT persisted. It is a reading aid for a quest currently on
-- screen, the account store keeps a bounded number of entries per section
-- (Core/Config.lua) and an unbounded per-quest table would compete with the
-- history sections for that budget. The account-wide language, which is the
-- durable preference, is stored; this is not.
--
-- Keyed by numeric quest ID, so a quest this addon could not match to a
-- database row (ambiguous or unmatched) has nothing to key on and cannot carry
-- an override -- which is correct, since it has no translated row to show
-- either.
local questLanguageOverrides = {}

-- nil = follow the account-wide setting; a code = this quest's own answer.
function UQ.GetQuestLanguageOverride(questId)
    if type(questId) ~= "number" then
        return nil
    end
    return questLanguageOverrides[questId]
end

-- Validated before it is stored, like the account-wide code: a value that
-- reached a lookup as a corrupt key would show a raw table name where the
-- quest text should be. The client's own locale is accepted alongside the four
-- this addon is translated into, because it is the "as the server wrote it"
-- end of the cycle and need not be one of them.
function UQ.SetQuestLanguageOverride(questId, code)
    if type(questId) ~= "number" then
        return false
    end
    if code == nil then
        questLanguageOverrides[questId] = nil
        return true
    end
    if not languageByCode[code] and code ~= Client.GetLocale() then
        return false
    end
    questLanguageOverrides[questId] = code
    return true
end

-- True while unrealUI is the one deciding. The settings window asks this to
-- know whether to draw its flag row at all: with unrealUI installed the
-- language is set there, and a second selector would be two controls writing
-- one value, only one of which unrealUI would honour.
function UQ.IsLanguageFollowingUnrealUI()
    return Locale.followsUnrealUI and true or false
end

local function Config()
    return UQ:GetModule("Config")
end

local function StoredLanguage()
    local config = Config()
    local code = config and config:Get("language")
    if languageByCode[code] then
        return code
    end
    return nil
end

-- Persists the choice and points the lookup at the new table. Text already on
-- screen is not retranslated: every label in this addon is written once when
-- its frame is built, so the caller (Core/Settings.lua) asks for a /reload.
-- Refused outright while unrealUI owns the language, so a stale flag row
-- cannot write a value that would then be ignored.
--
-- Returns true when the language actually changed.
function UQ.SetLanguage(code)
    if not languageByCode[code] then
        return false
    end
    if Locale.followsUnrealUI then
        return false
    end
    if code == active then
        return false
    end
    Activate(code)
    local config = Config()
    if config then
        config:Set("language", code)
    end
    return true
end

-- Resolution -----------------------------------------------------------------

-- unrealUI's namespace, but only if it carries the one function this needs.
-- Deliberately NOT IsAddOnLoaded, for the reason in the header.
local function UnrealUI()
    local host = Client.GetNamedObject("UnrealUI")
    if not host or type(host.GetLanguage) ~= "function" then
        return nil
    end
    return host
end

-- The two reads described in the header, authoritative one first. Returns nil
-- while unrealUI is present but has not yet said anything usable.
local function UnrealUILanguage(host)
    if host.ready then
        local ok, code = pcall(host.GetLanguage)
        if ok and languageByCode[code] then
            return code
        end
    end
    local profiles = Client.GetSavedVariableTable("UnrealUIProfiles")
    if profiles and languageByCode[profiles.language] then
        return profiles.language
    end
    return nil
end

-- First run on this installation, with no unrealUI to follow. English is the
-- default; a client already reporting one of this addon's other languages is a
-- better opening guess, and the player can still change it. The client locale
-- is a HINT only -- the language is a preference that has to survive playing an
-- enUS client in French.
local function FirstRunLanguage()
    local clientLocale = Client.GetLocale()
    if languageByCode[clientLocale] then
        return clientLocale
    end
    return DEFAULT_LANGUAGE
end

-- Decides the language. `force` is what ends the search: without it, an absent
-- unrealUI leaves the decision open so the poll can try again, exactly as
-- Settings:ResolveHost does. Returns true once the answer is final.
function Locale:Resolve(force)
    if self.settled then
        return true
    end

    local host = UnrealUI()
    if host then
        self.followsUnrealUI = true
        local code = UnrealUILanguage(host)
        if code then
            Activate(code)
            self.settled = true
            UQ:DeclareCapability("languageSource", "detected",
                "unrealUI is installed, so UnrealQuest draws its interface in the language set "
                .. "there ('" .. code .. "') and shows no flag selector of its own. Read through "
                .. "UnrealUI.GetLanguage once UnrealUI.ready is set, and from the UnrealUIProfiles "
                .. "SavedVariables global before that, which the client's own reader loads in time "
                .. "for this addon's first label")
            return true
        end
        -- Present but not ready and nothing persisted yet: keep the English
        -- default and let the poll ask again rather than guessing.
        return false
    end

    self.followsUnrealUI = false
    local stored = StoredLanguage()
    if stored then
        Activate(stored)
    else
        Activate(FirstRunLanguage())
    end

    if force then
        self.settled = true
        local config = Config()
        if config and not stored then
            config:Set("language", active)
        end
        UQ:DeclareCapability("languageSource", "detected",
            "unrealUI was not present after " .. POLL_SECONDS .. "s of polling, so UnrealQuest "
            .. "uses its own stored language ('" .. active .. "'), chosen with the flag row in the "
            .. "top-right of its own settings window. Polled rather than read once at load: "
            .. "nothing establishes the two addons' load order, the client's TOC dependency "
            .. "fields have no record in the compatibility database, and ADDON_LOADED has no "
            .. "probed record here")
    end
    return self.settled and true or false
end

-- Lifecycle -------------------------------------------------------------------

function Locale:OnInit()
    UQ:DeclareCapability("languageSource", "unverified",
        "where UnrealQuest's interface language comes from: unrealUI's setting when that addon "
        .. "is installed, this addon's own stored choice otherwise. Resolved by polling for the "
        .. "UnrealUI global and type-checking its GetLanguage; this line is what it says before "
        .. "that poll has answered")
    -- Runs at VARIABLES_LOADED, which is before any UnrealQuest label exists
    -- and after the client has loaded every addon's SavedVariables -- so the
    -- unrealUI case is normally already correct here, on the first frame.
    self:Resolve(false)
end

function Locale:OnEnable()
    if self.settled then
        return
    end
    local driver = UQ:GetModule("Driver")
    if not driver then
        -- No driver means no poll is possible, so decide now rather than
        -- leaving the language open for the rest of the session.
        self:Resolve(true)
        return
    end
    self.waited = 0
    driver:Schedule("locale.host", POLL_INTERVAL, function(elapsed)
        Locale.waited = (Locale.waited or 0) + (elapsed or POLL_INTERVAL)
        if Locale:Resolve(Locale.waited >= POLL_SECONDS) then
            local running = UQ:GetModule("Driver")
            if running then
                running:Unschedule("locale.host")
            end
        end
    end)
end

Locale.followsUnrealUI = false
Locale.settled = false
Locale.waited = 0

Activate(DEFAULT_LANGUAGE)
