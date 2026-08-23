"""Build the exhaustive UnrealQuest duplicate-title ambiguity database.

This is an offline data audit, not client runtime evidence. It mirrors the
matcher's title, level and race/class narrowing against every bundled locale,
then classifies the remaining description-only text tiebreaks. The generated
JSON is intentionally not loaded by the addon.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

import lupa


ROOT = Path(__file__).resolve().parents[1]
DATABASE = ROOT / "Database"
JSON_PATH = ROOT / "tools" / "ambiguous_quests.json"
REPORT_PATH = ROOT / "docs" / "AMBIGUOUS-QUESTS.md"

RACES = {
    1: "Human",
    2: "Orc",
    3: "Dwarf",
    4: "Night Elf",
    5: "Undead",
    6: "Tauren",
    7: "Gnome",
    8: "Troll",
}

CLASSES = {
    1: "Warrior",
    2: "Paladin",
    3: "Hunter",
    4: "Rogue",
    5: "Priest",
    7: "Shaman",
    8: "Mage",
    9: "Warlock",
    11: "Druid",
}

PROFILES = tuple((race_id, class_id) for race_id in RACES for class_id in CLASSES)
TOKEN_RE = re.compile(r"\$([A-Za-z])")
LAYOUT_TOKENS = {"B", "b"}
PERSONALIZATION_TOKENS = {"N", "n", "C", "c", "R", "r", "G", "g"}
GENDER_RE = re.compile(r"\$[Gg]([^:;]+):([^;]+);")

POST_FIX_STATUSES = {
    "fully_resolved": "Every simulated live description uniquely returns its own quest ID after known-token rendering.",
    "partially_resolved": "Known-token rendering proves an ID for only some candidates or gender branches.",
    "unresolved": "Description-only text still cannot prove one ID; retain ambiguity and the spatial union.",
    "unsafe": "At least one simulated description points at the wrong ID; the runtime matcher must refuse it.",
}

OBJECTIVE_AUDIT_STATUSES = {
    "fully_distinct": "Every candidate has a non-empty bundled objective-name set that uniquely identifies it inside the case.",
    "partially_distinct": "Exact bundled objective names distinguish only some candidates in the case.",
    "not_distinct": "Bundled objective names are missing or still shared; runtime must retain ambiguity unless live evidence proves more.",
}

COMBINED_EXACT_STATUSES = {
    "fully_resolved": "Every simulated candidate is identified by exact description and/or exact objective evidence.",
    "partially_resolved": "Exact evidence identifies only some candidates; the rest retain ambiguous identity.",
    "unresolved": "Neither exact description nor bundled objective-name evidence distinguishes any candidate.",
}

CLASSIFICATIONS = {
    "description_safe": {
        "meaning": "Raw description-only containment uniquely identifies every candidate and uses no substitution tokens.",
        "sharedFix": "Keep the existing text tiebreak; the candidate-union fallback remains the safety net for server text changes.",
    },
    "layout_substitution": {
        "meaning": "Descriptions are unique in raw data but contain only $B/$b layout tokens that the client removes or replaces live.",
        "sharedFix": "The implemented known-token renderer removes layout tokens before comparison; any remaining tie uses the candidate union.",
    },
    "personalization_substitution": {
        "meaning": "Descriptions are unique in raw data but contain player/race/class/gender or other live substitution tokens.",
        "sharedFix": "The implemented renderer expands known player/race/class tokens and selects the documented gender branch (or checks both if unavailable); remaining ties use the candidate union.",
    },
    "unknown_substitution": {
        "meaning": "Descriptions are unique in raw data but contain a $-token outside pfQuest's known N/C/R/B/G vocabulary.",
        "sharedFix": "Do not invent semantics for an undocumented token; retain ambiguity and use the candidate union.",
    },
    "description_collision": {
        "meaning": "At least one raw description produces zero or several containment hits inside its candidate set.",
        "sharedFix": "Text cannot prove one ID; retain ambiguous identity and use the candidate union for spatial consumers.",
    },
    "description_missing": {
        "meaning": "At least one candidate has no usable description.",
        "sharedFix": "Text cannot prove one ID; retain ambiguous identity and use the candidate union for spatial consumers.",
    },
    "description_misidentification": {
        "meaning": "At least one candidate's raw description uniquely points at a different candidate under current containment rules.",
        "sharedFix": "Do not trust a unique substring hit for this set; retain ambiguous identity and use the candidate union.",
    },
}


def name_key(text: object) -> str | None:
    """Byte-for-byte equivalent of Core/Namespace.lua UQ.NameKey."""
    if not isinstance(text, str):
        return None
    parts = bytearray()
    for byte in text.encode("utf-8"):
        if 65 <= byte <= 90:
            parts.append(byte + 32)
        elif 97 <= byte <= 122 or 48 <= byte <= 57 or byte >= 128:
            parts.append(byte)
    return parts.decode("utf-8") if parts else None


def integer(value: object) -> int | None:
    if isinstance(value, (int, float)) and int(value) == value:
        return int(value)
    return None


def field(table: object, key: str) -> object:
    if table is None:
        return None
    return table[key]


def matches_mask(mask: object, identity: int) -> bool:
    numeric = integer(mask)
    if numeric is None or numeric <= 0:
        return True
    bit = 1 << (identity - 1)
    return (numeric & bit) != 0


def matches_profile(record: object, race_id: int, class_id: int) -> bool:
    if record is None:
        return True
    return matches_mask(field(record, "race"), race_id) and matches_mask(
        field(record, "class"), class_id
    )


def profile_key(profile: tuple[int, int]) -> str:
    return f"r{profile[0]}:c{profile[1]}"


def profile_bitmap(profiles: list[tuple[int, int]]) -> str:
    """Compact exhaustive membership over model.profileOrder."""
    positions = {profile: index for index, profile in enumerate(PROFILES)}
    bits = 0
    for profile in profiles:
        bits |= 1 << positions[profile]
    width = (len(PROFILES) + 3) // 4
    return f"{bits:0{width}x}"


def text_value(texts: object, quest_id: int, key: str) -> str:
    record = texts[quest_id]
    value = field(record, key)
    return value if isinstance(value, str) else ""


def locale_table(database: object, base: str, locale: str) -> object:
    table = database[f"{base}_{locale}"]
    if table is None:
        table = database[f"{base}_enUS"]
    return table


def objective_signatures(
    database: object, quests: object, locale: str, quest_id: int
) -> set[tuple[str, str]]:
    record = quests[quest_id]
    relation = field(record, "obj")
    if relation is None:
        return set()
    sources = (
        ("U", "monster", locale_table(database, "units", locale)),
        ("I", "item", locale_table(database, "items", locale)),
        ("O", "gobject", locale_table(database, "objects", locale)),
    )
    signatures: set[tuple[str, str]] = set()
    for relation_key, objective_type, names in sources:
        values = field(relation, relation_key)
        if values is None or names is None:
            continue
        for _, source_id in values.items():
            key = name_key(names[source_id])
            if key:
                signatures.add((objective_type, key))
    return signatures


def objective_analysis(
    candidate_ids: tuple[int, ...], database: object, quests: object, locale: str
) -> dict:
    signatures = {
        quest_id: objective_signatures(database, quests, locale, quest_id)
        for quest_id in candidate_ids
    }
    outcomes: list[dict] = []
    for live_id in candidate_ids:
        live = signatures[live_id]
        hits = [
            candidate_id
            for candidate_id in candidate_ids
            if live and live.issubset(signatures[candidate_id])
        ]
        status = "correct" if len(hits) == 1 and hits[0] == live_id else "ambiguous"
        outcomes.append(
            {
                "questId": live_id,
                "status": status,
                "hits": hits,
                "signatureCount": len(live),
            }
        )

    statuses = [outcome["status"] for outcome in outcomes]
    if statuses and all(status == "correct" for status in statuses):
        status = "fully_distinct"
    elif "correct" in statuses:
        status = "partially_distinct"
    else:
        status = "not_distinct"
    return {
        "auditStatus": status,
        "outcomes": outcomes,
        "runtimeGuarantee": False,
        "note": "Upper bound from bundled U/I/O relation names; the runtime resolver uses only names actually parsed from the live quest log and refuses ties or unparsed lines.",
    }


def combined_exact_analysis(description: dict, objectives: dict) -> dict:
    description_by_id = {
        outcome["questId"]: outcome for outcome in description["postFixOutcomes"]
    }
    objective_by_id = {
        outcome["questId"]: outcome for outcome in objectives["outcomes"]
    }
    outcomes: list[dict] = []
    for quest_id, text_outcome in description_by_id.items():
        objective_outcome = objective_by_id[quest_id]
        text_correct = text_outcome["status"] == "correct"
        objective_correct = objective_outcome["status"] == "correct"
        if text_correct and objective_correct:
            source = "description+objective"
        elif text_correct:
            source = "description"
        elif objective_correct:
            source = "objective"
        else:
            source = None
        outcomes.append(
            {
                "questId": quest_id,
                "status": "correct" if source else "ambiguous",
                "source": source,
            }
        )
    statuses = [outcome["status"] for outcome in outcomes]
    if statuses and all(status == "correct" for status in statuses):
        status = "fully_resolved"
    elif "correct" in statuses:
        status = "partially_resolved"
    else:
        status = "unresolved"
    return {
        "auditStatus": status,
        "outcomes": outcomes,
        "runtimeGuarantee": False,
        "note": "Offline upper bound only; runtime accepts objective evidence solely from exact names actually parsed from every live objective line.",
    }


def rendered_description_branches(text: str) -> tuple[str | None, str | None]:
    """Model the known substitutions used by the runtime matcher.

    Fixed sentinel player values are sufficient for the audit: every candidate
    in one case sees the same name/race/class, so they do not affect which
    templates collide. Both documented UnitSex outcomes are audited.
    """
    if not text:
        return None, None
    rendered = re.sub(r"\$[Nn]", "Tester", text)
    rendered = re.sub(r"\$[Cc]", "Warrior", rendered)
    rendered = re.sub(r"\$[Rr]", "Orc", rendered)
    rendered = re.sub(r"\$[Bb]", "", rendered)
    variants = (
        GENDER_RE.sub(lambda match: match.group(1), rendered),
        GENDER_RE.sub(lambda match: match.group(2), rendered),
    )
    return name_key(variants[0]), name_key(variants[1])


def token_aware_outcomes(candidate_ids: tuple[int, ...], texts: object) -> list[dict]:
    candidate_branches = {
        quest_id: rendered_description_branches(text_value(texts, quest_id, "D"))
        for quest_id in candidate_ids
    }
    outcomes: list[dict] = []
    for live_id in candidate_ids:
        branch_results: list[dict] = []
        for branch_index, live_key in enumerate(candidate_branches[live_id]):
            if not live_key:
                continue
            exact = [
                quest_id
                for quest_id in candidate_ids
                if candidate_branches[quest_id][branch_index] == live_key
            ]
            contains: list[int] = []
            if not exact:
                contains = [
                    quest_id
                    for quest_id in candidate_ids
                    if candidate_branches[quest_id][branch_index]
                    and candidate_branches[quest_id][branch_index] in live_key
                ]
            matched = exact[0] if len(exact) == 1 else None
            if not exact and len(contains) == 1:
                matched = contains[0]
            branch_results.append(
                {
                    "liveKeySha1": hashlib.sha1(live_key.encode("utf-8")).hexdigest(),
                    "playerSex": 2 + branch_index,
                    "matchedQuestId": matched,
                    "exactHits": exact,
                    "containmentHits": contains,
                }
            )

        matched_ids = [branch["matchedQuestId"] for branch in branch_results]
        if branch_results and all(matched == live_id for matched in matched_ids):
            status = "correct"
        elif any(matched is not None and matched != live_id for matched in matched_ids):
            status = "wrong"
        elif any(matched == live_id for matched in matched_ids):
            status = "partial"
        else:
            status = "ambiguous"
        outcomes.append(
            {
                "questId": live_id,
                "status": status,
                "branches": branch_results,
            }
        )
    return outcomes


def description_analysis(candidate_ids: tuple[int, ...], texts: object) -> dict:
    tokens: set[str] = set()
    outcomes: list[dict] = []
    missing = False
    wrong = False
    ambiguous = False

    for live_id in candidate_ids:
        description = text_value(texts, live_id, "D")
        tokens.update(TOKEN_RE.findall(description))
        wanted = name_key(description)
        hits: list[int] = []
        if wanted:
            for candidate_id in candidate_ids:
                detail = name_key(text_value(texts, candidate_id, "D"))
                if detail and detail in wanted:
                    hits.append(candidate_id)
        else:
            missing = True

        if len(hits) == 1 and hits[0] == live_id:
            status = "correct"
        elif len(hits) == 1:
            status = "wrong"
            wrong = True
        else:
            status = "ambiguous"
            ambiguous = True
        outcomes.append({"questId": live_id, "status": status, "hits": hits})

    if wrong:
        classification = "description_misidentification"
    elif missing:
        classification = "description_missing"
    elif ambiguous:
        classification = "description_collision"
    elif tokens - LAYOUT_TOKENS - PERSONALIZATION_TOKENS:
        classification = "unknown_substitution"
    elif tokens - LAYOUT_TOKENS:
        classification = "personalization_substitution"
    elif tokens:
        classification = "layout_substitution"
    else:
        classification = "description_safe"

    fixed_outcomes = token_aware_outcomes(candidate_ids, texts)
    fixed_statuses = [outcome["status"] for outcome in fixed_outcomes]
    if "wrong" in fixed_statuses:
        post_fix_status = "unsafe"
    elif fixed_statuses and all(status == "correct" for status in fixed_statuses):
        post_fix_status = "fully_resolved"
    elif "correct" in fixed_statuses or "partial" in fixed_statuses:
        post_fix_status = "partially_resolved"
    else:
        post_fix_status = "unresolved"

    return {
        "classification": classification,
        "tokens": sorted(tokens),
        "outcomes": outcomes,
        "recommendedHandling": CLASSIFICATIONS[classification]["sharedFix"],
        "postFixStatus": post_fix_status,
        "postFixOutcomes": fixed_outcomes,
    }


def possible_live_levels(candidate_ids: list[int], quests: object) -> list[int | None]:
    levels = sorted(
        {
            level
            for quest_id in candidate_ids
            if (level := integer(field(quests[quest_id], "lvl"))) is not None
        }
    )
    return levels or [None]


def same_level_candidates(
    candidate_ids: list[int], live_level: int | None, quests: object
) -> list[int]:
    narrowed: list[int] = []
    for quest_id in candidate_ids:
        record = quests[quest_id]
        record_level = integer(field(record, "lvl"))
        if (
            record is not None
            and live_level is not None
            and record_level is not None
            and record_level != live_level
        ):
            continue
        narrowed.append(quest_id)
    return narrowed


def classify_group(
    title_key: str,
    candidate_ids: list[int],
    texts: object,
    quests: object,
    database: object,
    locale: str,
) -> dict:
    title = text_value(texts, candidate_ids[0], "T")
    cases: list[dict] = []
    level_resolved_ids: set[int] = set()
    eligibility_resolved_ids: set[int] = set()

    for live_level in possible_live_levels(candidate_ids, quests):
        level_candidates = same_level_candidates(candidate_ids, live_level, quests)
        if len(level_candidates) == 1:
            level_resolved_ids.add(level_candidates[0])
            continue

        profile_sets: dict[tuple[int, ...], list[tuple[int, int]]] = defaultdict(list)
        for profile in PROFILES:
            refined = tuple(
                quest_id
                for quest_id in level_candidates
                if matches_profile(quests[quest_id], profile[0], profile[1])
            )
            if len(refined) == 1:
                eligibility_resolved_ids.add(refined[0])
            elif len(refined) > 1:
                profile_sets[refined].append(profile)

        for refined, profiles in sorted(profile_sets.items()):
            analysis = description_analysis(refined, texts)
            objectives = objective_analysis(refined, database, quests, locale)
            cases.append(
                {
                    "liveLevel": live_level,
                    "candidateQuestIds": list(refined),
                    "profileCount": len(profiles),
                    "profileBitmap": profile_bitmap(profiles),
                    "description": analysis,
                    "objectives": objectives,
                    "combinedExact": combined_exact_analysis(analysis, objectives),
                }
            )

    cases.sort(
        key=lambda case: (
            case["liveLevel"] is None,
            case["liveLevel"] if case["liveLevel"] is not None else -1,
            case["candidateQuestIds"],
        )
    )
    return {
        "title": title,
        "titleKey": title_key,
        "questIds": candidate_ids,
        "levelResolvedQuestIds": sorted(level_resolved_ids),
        "eligibilityResolvedQuestIds": sorted(eligibility_resolved_ids),
        "ambiguousCases": cases,
    }


def load_database() -> tuple[object, object, list[str], list[Path]]:
    locale_quest_files = sorted(
        path for path in DATABASE.glob("*/quests.lua") if path.parent.name != "Waypoints"
    )
    locales = [path.parent.name for path in locale_quest_files]
    locale_name_files = [
        DATABASE / locale / filename
        for locale in locales
        for filename in ("units.lua", "objects.lua", "items.lua")
        if (DATABASE / locale / filename).exists()
    ]
    source_files = [
        DATABASE / "init.lua",
        DATABASE / "units.lua",
        DATABASE / "objects.lua",
        DATABASE / "items.lua",
        DATABASE / "quests.lua",
        *locale_name_files,
        *locale_quest_files,
    ]
    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
    for path in source_files:
        runtime.execute(path.read_text(encoding="utf-8"))
    database = runtime.globals().UnrealQuestData
    return database, database["quests"], locales, source_files


def source_digest(paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.relative_to(ROOT).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def build_database() -> dict:
    database, quests, locales, source_files = load_database()
    locale_results: dict[str, dict] = {}
    global_classes: Counter[str] = Counter()
    global_post_fix: Counter[str] = Counter()
    global_objectives: Counter[str] = Counter()
    global_combined: Counter[str] = Counter()
    global_ambiguous_ids: set[int] = set()

    for locale in locales:
        texts = database[f"quests_{locale}"]
        title_index: dict[str, list[int]] = defaultdict(list)
        for quest_id, record in texts.items():
            numeric_id = integer(quest_id)
            key = name_key(field(record, "T"))
            if numeric_id is not None and key:
                title_index[key].append(numeric_id)

        duplicate_groups = 0
        ambiguous_groups: list[dict] = []
        locale_classes: Counter[str] = Counter()
        locale_post_fix: Counter[str] = Counter()
        locale_objectives: Counter[str] = Counter()
        locale_combined: Counter[str] = Counter()
        locale_ambiguous_ids: set[int] = set()
        total_cases = 0

        for title_key, ids in sorted(title_index.items()):
            candidate_ids = sorted(ids)
            if len(candidate_ids) <= 1:
                continue
            duplicate_groups += 1
            group = classify_group(
                title_key, candidate_ids, texts, quests, database, locale
            )
            if not group["ambiguousCases"]:
                continue
            ambiguous_groups.append(group)
            for case in group["ambiguousCases"]:
                classification = case["description"]["classification"]
                post_fix_status = case["description"]["postFixStatus"]
                objective_status = case["objectives"]["auditStatus"]
                combined_status = case["combinedExact"]["auditStatus"]
                locale_classes[classification] += 1
                global_classes[classification] += 1
                locale_post_fix[post_fix_status] += 1
                global_post_fix[post_fix_status] += 1
                locale_objectives[objective_status] += 1
                global_objectives[objective_status] += 1
                locale_combined[combined_status] += 1
                global_combined[combined_status] += 1
                total_cases += 1
                locale_ambiguous_ids.update(case["candidateQuestIds"])
                global_ambiguous_ids.update(case["candidateQuestIds"])

        locale_results[locale] = {
            "summary": {
                "indexedTitles": sum(len(ids) for ids in title_index.values()),
                "duplicateTitleGroups": duplicate_groups,
                "ambiguousTitleGroups": len(ambiguous_groups),
                "ambiguousCases": total_cases,
                "ambiguousQuestIds": len(locale_ambiguous_ids),
                "casesByClassification": dict(sorted(locale_classes.items())),
                "casesByPostFixStatus": dict(sorted(locale_post_fix.items())),
                "casesByObjectiveAuditStatus": dict(sorted(locale_objectives.items())),
                "casesByCombinedExactStatus": dict(sorted(locale_combined.items())),
            },
            "groups": ambiguous_groups,
        }

    return {
        "schemaVersion": 2,
        "purpose": "Offline classification of every bundled duplicate-title quest case that can remain ambiguous after level and race/class filtering.",
        "runtimeEvidence": False,
        "sourceSha256": source_digest(source_files),
        "model": {
            "clientTextContract": "GetQuestLogQuestText returns questDescription only, with live substitutions applied.",
            "raceIds": {str(key): value for key, value in RACES.items()},
            "classIds": {str(key): value for key, value in CLASSES.items()},
            "profileOrder": [profile_key(profile) for profile in PROFILES],
            "profileBitmapEncoding": "Hex bitset; bit N corresponds to profileOrder[N].",
            "classificationDefinitions": CLASSIFICATIONS,
            "postFixStatusDefinitions": POST_FIX_STATUSES,
            "objectiveAuditStatusDefinitions": OBJECTIVE_AUDIT_STATUSES,
            "combinedExactStatusDefinitions": COMBINED_EXACT_STATUSES,
            "tokenAwareMatcher": "Known $N/$C/$R/$B substitutions plus the documented UnitSex-selected $G branch (both outcomes audited, both tried if unavailable); exact normalized description first, then unique containment; objectives excluded.",
            "liveObjectiveMatcher": "Exact parsed live objective name and type must match every line against one bundled U/I/O candidate; unparsed lines, ties and text/objective disagreement retain ambiguity.",
            "levenshteinRuntimePolicy": "disabled: a non-zero best distance is similarity, not proof; distance zero is already covered by exact normalized matching.",
        },
        "summary": {
            "locales": len(locales),
            "ambiguousQuestIdsAcrossLocales": len(global_ambiguous_ids),
            "casesByClassificationAcrossLocales": dict(sorted(global_classes.items())),
            "casesByPostFixStatusAcrossLocales": dict(sorted(global_post_fix.items())),
            "casesByObjectiveAuditStatusAcrossLocales": dict(sorted(global_objectives.items())),
            "casesByCombinedExactStatusAcrossLocales": dict(sorted(global_combined.items())),
        },
        "locales": locale_results,
    }


def markdown_report(data: dict) -> str:
    totals = data["summary"]["casesByClassificationAcrossLocales"]
    post_fix = data["summary"]["casesByPostFixStatusAcrossLocales"]
    objectives = data["summary"]["casesByObjectiveAuditStatusAcrossLocales"]
    combined = data["summary"]["casesByCombinedExactStatusAcrossLocales"]
    all_cases = sum(totals.values())
    fully_resolved = post_fix.get("fully_resolved", 0)
    partially_resolved = post_fix.get("partially_resolved", 0)
    unresolved = post_fix.get("unresolved", 0)
    unsafe = post_fix.get("unsafe", 0)
    lines = [
        "# Ambiguous quest title audit",
        "",
        "Generated by `tools/classify_ambiguous_quests.py`; do not edit by hand.",
        "This is an offline bundled-data audit, not client runtime evidence.",
        "",
        "The matcher still keeps uncertain identity honest (`questId = nil`).",
        "World-map and minimap rendering use the safe candidate union, so every",
        "case below is covered by the same spatial fallback even when text fails.",
        "",
        "## Summary by locale",
        "",
        "| Locale | Duplicate titles | Ambiguous groups | Ambiguous cases | Quest IDs |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for locale, result in data["locales"].items():
        summary = result["summary"]
        lines.append(
            f"| {locale} | {summary['duplicateTitleGroups']} | "
            f"{summary['ambiguousTitleGroups']} | {summary['ambiguousCases']} | "
            f"{summary['ambiguousQuestIds']} |"
        )

    lines.extend(
        [
            "",
            "## Shared cause classes",
            "",
            "Counts are ambiguity cases (one level plus one distinct eligible candidate set),",
            "summed across locales.",
            "",
            "| Classification | Cases | Shared handling |",
            "| --- | ---: | --- |",
        ]
    )
    for classification, definition in CLASSIFICATIONS.items():
        lines.append(
            f"| `{classification}` | {totals.get(classification, 0)} | "
            f"{definition['sharedFix']} |"
        )

    lines.extend(
        [
            "",
            "## Result after the token-aware fix",
            "",
            "This models the implemented runtime algorithm: render known player/layout tokens,",
            "select the documented gender branch, try exact normalized description equality",
            "first, then unique containment, and",
            "never use objective text from this description-only API.",
            "",
            "| Result | Cases | Meaning |",
            "| --- | ---: | --- |",
        ]
    )
    for status, meaning in POST_FIX_STATUSES.items():
        lines.append(f"| `{status}` | {post_fix.get(status, 0)} | {meaning} |")

    lines.extend(
        [
            "",
            "## Exact-objective audit",
            "",
            "The runtime now parses every live objective through the client's documented",
            "format strings and requires exact name + relation-type agreement for one candidate.",
            "The counts below are an offline upper bound from bundled U/I/O relations, because",
            "the database cannot know which objective lines a modified server actually sends.",
            "",
            "| Result | Cases | Meaning |",
            "| --- | ---: | --- |",
        ]
    )
    for status, meaning in OBJECTIVE_AUDIT_STATUSES.items():
        lines.append(f"| `{status}` | {objectives.get(status, 0)} | {meaning} |")

    lines.extend(
        [
            "",
            "## Combined exact-evidence upper bound",
            "",
            "This combines exact description evidence with the exact-objective audit.",
            "It remains an offline upper bound, not a promise that every live quest log",
            "contains enough parseable objective evidence.",
            "",
            "| Result | Cases | Meaning |",
            "| --- | ---: | --- |",
        ]
    )
    for status, meaning in COMBINED_EXACT_STATUSES.items():
        lines.append(f"| `{status}` | {combined.get(status, 0)} | {meaning} |")

    lines.extend(
        [
            "",
            "## Fuzzy-score safety decision",
            "",
            "pfQuest's Levenshtein score remains reference-only. A non-zero best distance",
            "proves only that one candidate is closer, not that it is the live quest, so it",
            "has no runtime authority. Distance zero is already handled by exact normalized",
            "matching. This preserves the no-guessed-ID requirement.",
        ]
    )

    lines.extend(
        [
            "",
            "## Fix leverage",
            "",
            "| Strategy | Cases | Result |",
            "| --- | ---: | --- |",
            f"| Token-aware description matching (implemented) | {fully_resolved} | Fully recovers these cases in the bundled-data simulation. |",
            f"| Token-aware partial recovery | {partially_resolved} | Some candidates or gender branches recover; all other outcomes stay ambiguous. |",
            f"| No safe description-only identity | {unresolved} | Remains ambiguous; spatial union is the correct fallback. |",
            f"| Unsafe simulated outcomes | {unsafe} | Must remain zero; validation fails if a result escapes its candidate set. |",
            f"| Candidate-union spatial fallback (implemented) | {all_cases} | Prevents any case left ambiguous at runtime from erasing world-map/minimap content. |",
            "",
            "## Interpretation",
            "",
            "- Known layout and personalization substitutions share the 879/906 failure",
            "  mechanism and are handled by one renderer derived from pfQuest's token set.",
            "- Tokens outside that vocabulary remain explicit unknowns rather than receiving",
            "  invented substitution semantics.",
            "- Exact equality is preferred over fuzzy scoring; no first tied candidate is selected.",
            "- Missing or colliding descriptions remain unresolved instead of receiving a guessed ID.",
            "- The complete per-title/per-level/per-profile records are in",
            "  `tools/ambiguous_quests.json`.",
            "",
        ]
    )
    return "\n".join(lines)


def validate_database(data: dict) -> None:
    checked = 0
    found_betrayal = False
    found_betrayal_objectives = False
    for locale, locale_data in data["locales"].items():
        seen_groups: set[str] = set()
        for group in locale_data["groups"]:
            title_key = group["titleKey"]
            if title_key in seen_groups:
                raise AssertionError(f"duplicate generated group: {locale}/{title_key}")
            seen_groups.add(title_key)
            group_ids = set(group["questIds"])
            for case in group["ambiguousCases"]:
                checked += 1
                candidate_ids = set(case["candidateQuestIds"])
                if len(candidate_ids) < 2 or not candidate_ids.issubset(group_ids):
                    raise AssertionError(f"invalid candidates: {locale}/{title_key}")
                bitmap_count = bin(int(case["profileBitmap"], 16)).count("1")
                if bitmap_count != case["profileCount"]:
                    raise AssertionError(f"profile bitmap mismatch: {locale}/{title_key}")
                description = case["description"]
                if description["classification"] not in CLASSIFICATIONS:
                    raise AssertionError(f"unknown classification: {locale}/{title_key}")
                if description["postFixStatus"] not in POST_FIX_STATUSES:
                    raise AssertionError(f"unknown post-fix status: {locale}/{title_key}")
                outcome_ids = {outcome["questId"] for outcome in description["outcomes"]}
                if outcome_ids != candidate_ids:
                    raise AssertionError(f"description coverage mismatch: {locale}/{title_key}")
                for outcome in description["outcomes"]:
                    if not set(outcome["hits"]).issubset(candidate_ids):
                        raise AssertionError(f"description hit escaped candidates: {locale}/{title_key}")
                fixed_ids = {
                    outcome["questId"] for outcome in description["postFixOutcomes"]
                }
                if fixed_ids != candidate_ids:
                    raise AssertionError(f"post-fix coverage mismatch: {locale}/{title_key}")
                for outcome in description["postFixOutcomes"]:
                    for branch in outcome["branches"]:
                        if not set(branch["exactHits"]).issubset(candidate_ids):
                            raise AssertionError(f"exact hit escaped candidates: {locale}/{title_key}")
                        if not set(branch["containmentHits"]).issubset(candidate_ids):
                            raise AssertionError(f"containment hit escaped candidates: {locale}/{title_key}")
                        matched = branch["matchedQuestId"]
                        if matched is not None and matched not in candidate_ids:
                            raise AssertionError(f"match escaped candidates: {locale}/{title_key}")
                objectives = case["objectives"]
                if objectives["auditStatus"] not in OBJECTIVE_AUDIT_STATUSES:
                    raise AssertionError(f"unknown objective status: {locale}/{title_key}")
                objective_ids = {
                    outcome["questId"] for outcome in objectives["outcomes"]
                }
                if objective_ids != candidate_ids:
                    raise AssertionError(f"objective coverage mismatch: {locale}/{title_key}")
                for outcome in objectives["outcomes"]:
                    if not set(outcome["hits"]).issubset(candidate_ids):
                        raise AssertionError(f"objective hit escaped candidates: {locale}/{title_key}")
                combined = case["combinedExact"]
                if combined["auditStatus"] not in COMBINED_EXACT_STATUSES:
                    raise AssertionError(f"unknown combined status: {locale}/{title_key}")
                combined_ids = {
                    outcome["questId"] for outcome in combined["outcomes"]
                }
                if combined_ids != candidate_ids:
                    raise AssertionError(f"combined coverage mismatch: {locale}/{title_key}")
                for outcome in combined["outcomes"]:
                    if outcome["status"] not in ("correct", "ambiguous"):
                        raise AssertionError(f"unsafe combined status: {locale}/{title_key}")
                    if outcome["source"] not in (
                        None,
                        "description",
                        "objective",
                        "description+objective",
                    ):
                        raise AssertionError(f"unknown combined source: {locale}/{title_key}")
                if (
                    locale == "enUS"
                    and title_key == "betrayalfromwithin"
                    and candidate_ids == {879, 906}
                    and description["classification"] == "personalization_substitution"
                    and description["postFixStatus"] == "fully_resolved"
                ):
                    found_betrayal = True
                    objective_by_id = {
                        outcome["questId"]: outcome
                        for outcome in objectives["outcomes"]
                    }
                    if (
                        objective_by_id[879]["status"] == "correct"
                        and objective_by_id[906]["status"] == "ambiguous"
                    ):
                        found_betrayal_objectives = True
    expected = sum(
        data["summary"]["casesByClassificationAcrossLocales"].values()
    )
    if checked != expected:
        raise AssertionError(f"case count mismatch: checked {checked}, summary {expected}")
    post_fix_expected = sum(
        data["summary"]["casesByPostFixStatusAcrossLocales"].values()
    )
    if checked != post_fix_expected:
        raise AssertionError(
            f"post-fix count mismatch: checked {checked}, summary {post_fix_expected}"
        )
    if data["summary"]["casesByPostFixStatusAcrossLocales"].get("unsafe", 0):
        raise AssertionError("token-aware matcher produced an unsafe simulated outcome")
    objective_expected = sum(
        data["summary"]["casesByObjectiveAuditStatusAcrossLocales"].values()
    )
    if checked != objective_expected:
        raise AssertionError(
            f"objective count mismatch: checked {checked}, summary {objective_expected}"
        )
    combined_expected = sum(
        data["summary"]["casesByCombinedExactStatusAcrossLocales"].values()
    )
    if checked != combined_expected:
        raise AssertionError(
            f"combined count mismatch: checked {checked}, summary {combined_expected}"
        )
    if not found_betrayal:
        raise AssertionError("879/906 description-substitution regression is missing")
    if not found_betrayal_objectives:
        raise AssertionError("879/906 exact-objective regression is missing")


def serialized_outputs() -> tuple[str, str]:
    data = build_database()
    validate_database(data)
    json_text = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    return json_text, markdown_report(data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check", action="store_true", help="fail if generated artifacts are missing or stale"
    )
    args = parser.parse_args()

    json_text, report_text = serialized_outputs()
    outputs = ((JSON_PATH, json_text), (REPORT_PATH, report_text))
    if args.check:
        stale = [path for path, content in outputs if not path.exists() or path.read_text(encoding="utf-8") != content]
        if stale:
            for path in stale:
                print(f"STALE {path.relative_to(ROOT)}")
            return 1
        print("ambiguous quest database is current")
        return 0

    for path, content in outputs:
        path.write_text(content, encoding="utf-8", newline="\n")
        print(f"wrote {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
