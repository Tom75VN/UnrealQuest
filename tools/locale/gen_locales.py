# -*- coding: utf-8 -*-
"""Emits unrealQuest/Locales/*.lua from the catalogs beside this file.

One source of truth for four languages, so a key cannot exist in one file and
be forgotten in another. Verifies that every key used by the addon has an
English entry and that every translation carries the same format placeholders
as its English original before writing anything.
"""

import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# tools/locale/ -> tools/ -> the addon root.
ADDON = os.path.dirname(os.path.dirname(HERE))

import cat_common
import cat_cmd_help
import cat_cmd_reports
import cat_plural

EN, FR, RU, CN = 0, 1, 2, 3

LANGUAGES = [
    ("enUS", EN, "English"),
    ("frFR", FR, "French"),
    ("ruRU", RU, "Russian"),
    ("zhCN", CN, "Simplified Chinese"),
]

# Plural selectors, one per language that needs one. English is the built-in
# rule in Core/Locale.lua, so it registers nothing.
SELECTORS = {
    "frFR": (
        "-- French treats 0 and 1 alike: \"0 quete\", not \"0 quetes\".\n"
        "UQ.RegisterLocalePlural(\"frFR\", function(n)\n"
        "    if n < 2 then\n"
        "        return \"ONE\"\n"
        "    end\n"
        "    return \"OTHER\"\n"
        "end)\n"
    ),
    "ruRU": (
        "-- The standard Russian rule: ONE for 1, 21, 31 ... (but not 11),\n"
        "-- FEW for 2-4, 22-24 ... (but not 12-14), MANY for the rest.\n"
        "--\n"
        "-- The % operator rather than math.mod: Core/Namespace.lua's quest-colour\n"
        "-- hash already runs % on this client, where math.mod is a Lua 5.0 spelling\n"
        "-- with no runtime record here.\n"
        "UQ.RegisterLocalePlural(\"ruRU\", function(n)\n"
        "    local hundreds = n % 100\n"
        "    if hundreds >= 11 and hundreds <= 14 then\n"
        "        return \"MANY\"\n"
        "    end\n"
        "    local tens = n % 10\n"
        "    if tens == 1 then\n"
        "        return \"ONE\"\n"
        "    end\n"
        "    if tens >= 2 and tens <= 4 then\n"
        "        return \"FEW\"\n"
        "    end\n"
        "    return \"MANY\"\n"
        "end)\n"
    ),
    "zhCN": (
        "-- Chinese does not inflect for number: every count uses one form.\n"
        "UQ.RegisterLocalePlural(\"zhCN\", function()\n"
        "    return \"OTHER\"\n"
        "end)\n"
    ),
}

HEADER = """--[[
UnrealQuest / Locales/%(code)s.lua

The %(name)s string catalog. One flat key -> text table, registered with
Core/Locale.lua at file load.

GENERATED, and meant to be edited by hand afterwards or regenerated from
tools -- either way the rules are the same:

  * enUS is the fallback for every other language. A key missing here shows up
    in game as its own upper-case identifier, which is the findable failure.
  * Keep the format placeholders. %%s is filled by the caller in the order it
    passes them, and Core/Locale.lua guards the string.format call, so a
    dropped placeholder degrades to the unformatted line rather than taking a
    settings page or a tooltip down.
  * Counted strings live in the _ONE / _FEW / _MANY / _OTHER suffixed keys and
    are reached through UQ.LN, which passes the count as the first argument.
    Only the forms this language actually uses need to exist.
  * A leading "/uq ..." in a help row is a COMMAND and is never translated --
    typing it is how it works. Only the description after it is.

Encoding: UTF-8, no BOM. Whether the client's font can draw these glyphs is a
property of the client and not something this addon can fix by shipping a font
(knowledge.json / fonts.setfont_silent_failure); the flag selector stays
usable in every language for exactly that reason. Accented Latin text is the
one case that can be worked around, so the generator folds it to plain ASCII
on the way out -- "quete", never the accented spelling. Hand-edit this file
the same way, or the accent comes back as a blank box in game.
]]

local UQ = UnrealQuest

"""


# The client's font draws the ASCII range and nothing else reliably, so an
# accented French glyph comes out as a blank or a box rather than a letter
# (knowledge.json / fonts.setfont_silent_failure: a font this addon ships
# cannot fix that). unrealUI answers the same problem the same way -- its
# frFR catalog is written unaccented by hand. Here the catalog keeps proper
# French and the fold happens on the way out, so a translator never has to
# remember the rule and a hand-typed accent cannot reach the game.
ASCII_FOLD = [
    (u"àáâãäå", u"a"),
    (u"ç", u"c"),
    (u"èéêë", u"e"),
    (u"ìíîï", u"i"),
    (u"ñ", u"n"),
    (u"òóôõö", u"o"),
    (u"ùúûü", u"u"),
    (u"ýÿ", u"y"),
    (u"ÀÁÂÃÄÅ", u"A"),
    (u"Ç", u"C"),
    (u"ÈÉÊË", u"E"),
    (u"ÌÍÎÏ", u"I"),
    (u"Ñ", u"N"),
    (u"ÒÓÔÕÖ", u"O"),
    (u"ÙÚÛÜ", u"U"),
    (u"Ý", u"Y"),
]

ASCII_PAIRS = [
    (u"œ", u"oe"), (u"Œ", u"OE"),
    (u"æ", u"ae"), (u"Æ", u"AE"),
    (u"ß", u"ss"),
    # Typographic punctuation is outside the drawable range too.
    (u"« ", u'"'), (u" »", u'"'),
    (u"«", u'"'), (u"»", u'"'),
    (u"‘", u"'"), (u"’", u"'"),
    (u"“", u'"'), (u"”", u'"'),
    (u"–", u"-"), (u"—", u"--"),
    (u"…", u"..."),
    (u" ", u" "),
]


def ascii_fold(text):
    """Latin text reduced to the glyphs the client can actually draw."""
    for old, new in ASCII_PAIRS:
        text = text.replace(old, new)
    for group, plain in ASCII_FOLD:
        for ch in group:
            text = text.replace(ch, plain)
    return text


# Languages whose catalog text is folded to ASCII on the way out. Russian and
# Chinese are not Latin at all: folding is meaningless there, and the flag
# selector stays reachable in every language for exactly that reason.
FOLDED = ("frFR",)


def lua_quote(text):
    out = text.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("\n", "\\n").replace("\r", "")
    return '"%s"' % out


PLACEHOLDER = re.compile(r"%[-+ #0-9.]*[a-zA-Z%]")


def placeholders(text):
    return [p for p in PLACEHOLDER.findall(text) if p != "%%"]


def collect():
    """key -> (en, fr, ru, cn); plural keys are already suffixed."""
    flat = {}
    for source in (cat_common.STRINGS, cat_cmd_help.STRINGS, cat_cmd_reports.STRINGS):
        for key, row in source.items():
            assert key not in flat, "duplicate key: " + key
            assert len(row) == 4, key
            flat[key] = row
    for key, forms in cat_plural.PLURALS.items():
        for form, row in forms.items():
            suffixed = key + "_" + form
            assert suffixed not in flat, "duplicate key: " + suffixed
            flat[suffixed] = row
    return flat


def used_keys():
    """Every key the Lua source actually asks for."""
    call = re.compile(r'UQ\.(L|LN)\(\s*"([A-Z][A-Z0-9_]*)"')
    table = re.compile(r'"((?:CMD_HELP|TRACKER_HINT|MARK|NPC_CATEGORY)_[A-Z0-9_]*)"')
    singular, plural = set(), set()
    for root, dirs, files in os.walk(ADDON):
        dirs[:] = [d for d in dirs
                   if d not in ("Database", "docs", "tools", "media", "screenshots",
                                ".git", "Locales")]
        for name in files:
            if not name.endswith(".lua"):
                continue
            text = io.open(os.path.join(root, name), encoding="utf-8").read()
            for kind, key in call.findall(text):
                (plural if kind == "LN" else singular).add(key)
            for key in table.findall(text):
                singular.add(key)
    singular.discard("KEY")          # the doc example in Core/Locale.lua
    return singular - plural, plural


def main():
    flat = collect()
    singular, plural = used_keys()

    missing = sorted(k for k in singular if k not in flat)
    for key in plural:
        if not any((key + "_" + form) in flat for form in
                   ("ONE", "FEW", "MANY", "OTHER")):
            missing.append(key + "_*")
    if missing:
        print("MISSING English entries for:")
        for key in missing:
            print("   ", key)
        return 1

    known = set(singular)
    for key in plural:
        for form in ("ONE", "FEW", "MANY", "OTHER"):
            known.add(key + "_" + form)
    unused = sorted(k for k in flat if k not in known)
    if unused:
        print("UNUSED catalog entries (harmless, but check for a typo):")
        for key in unused:
            print("   ", key)

    # Placeholder parity: a translation that drops or invents a %s would be
    # silently wrong at runtime, since the format call is deliberately guarded.
    problems = []
    for key, row in sorted(flat.items()):
        english = row[EN]
        if english is None:
            continue
        want = placeholders(english)
        for code, index, _name in LANGUAGES[1:]:
            text = row[index]
            if text is None:
                continue
            if placeholders(text) != want:
                problems.append("%s [%s]: %r vs English %r"
                                % (key, code, placeholders(text), want))
    if problems:
        print("PLACEHOLDER MISMATCH:")
        for line in problems:
            print("   ", line)
        return 1

    for code, index, name in LANGUAGES:
        rows = []
        for key in sorted(flat):
            text = flat[key][index]
            if text is None:
                continue
            if code in FOLDED:
                text = ascii_fold(text)
            if index != EN and text == flat[key][EN]:
                # Identical to English: the fallback already answers, so the
                # entry is dropped rather than duplicated.
                continue
            rows.append("    [%s] = %s," % (lua_quote(key), lua_quote(text)))

        body = HEADER % {"code": code, "name": name}
        body += "UQ.RegisterLocale(%s, {\n%s\n})\n" % (lua_quote(code), "\n".join(rows))
        selector = SELECTORS.get(code)
        if selector:
            body += "\n" + selector

        path = os.path.join(ADDON, "Locales", code + ".lua")
        io.open(path, "w", encoding="utf-8", newline="\n").write(body)
        print("wrote %s (%d entries)" % (path, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
